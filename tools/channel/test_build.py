import gzip
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.channel import build


ROOT = Path(__file__).resolve().parents[2]
USIGN = ROOT / "tests/host/prefix/bin/usign"


class ChannelBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()
        self.data = self.root / "data"
        self.data.mkdir()
        self.out = self.root / "out"
        self.previous_path = self.root / "previous.json"

    def tearDown(self):
        self.temp.cleanup()

    def add_packages(self, version="1.0-r1", arches=("aarch64_generic", "x86_64"), packages=None, apk=True):
        """Lay files out as the SDKs write them: <target>/<feed>/<file>; noarch apks carry no arch."""
        names = packages or build.PACKAGE_NAMES
        for arch in arches:
            feed = self.packages / arch / "aetherproxy"
            feed.mkdir(parents=True, exist_ok=True)
            for name in names:
                pkg_arch = "all" if name in build.ARCH_ALL else arch
                (feed / f"{name}_{version}_{pkg_arch}.ipk").write_bytes(f"ipk:{name}:{version}:{pkg_arch}:{arch}".encode())
                if apk:
                    (feed / f"{name}-{version}.apk").write_bytes(f"apk:{name}:{version}:{pkg_arch}:{arch}".encode())

    def add_data(self):
        for name in build.DATA_NAMES:
            (self.data / f"{name}.txt").write_text(f"{name}\nsecond\n", encoding="utf-8")

    def previous(self, packages=None, data=None):
        manifest = {
            "schema": 2,
            "generated": "2026-01-01T00:00:00Z",
            "packages": packages or {},
            "data": data or {},
        }
        self.previous_path.write_text(json.dumps(manifest), encoding="utf-8")
        return manifest

    def run_build(self, data=None, previous=None):
        return build.build_to_dir(self.out, self.packages, data, previous)

    def test_complete_manifest_copies_assets_and_computes_data_fields(self):
        self.add_packages()
        self.add_data()
        self.run_build(self.data)
        manifest = json.loads((self.out / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], 2)
        self.assertTrue(manifest["generated"].endswith("Z"))
        self.assertEqual(set(manifest["packages"]), set(build.PACKAGE_NAMES))
        # noarch packages collapse to "all"; xray-core keeps one entry per target
        self.assertEqual(set(manifest["packages"]["aether-proxy"]["current"]["assets"]), {"all"})
        self.assertEqual(set(manifest["packages"]["xray-core"]["current"]["assets"]), {"aarch64_generic", "x86_64"})
        self.assertEqual(set(manifest["packages"]["chinadns-ng"]["current"]["assets"]), {"aarch64_generic", "x86_64"})
        asset = manifest["packages"]["aether-proxy"]["current"]["assets"]["all"]["ipk"]
        content = (self.out / asset["url"]).read_bytes()
        self.assertEqual(asset["size"], len(content))
        self.assertEqual(asset["sha256"], build.sha256(content))
        # arch-specific apks get the architecture in the asset name, so targets do not collide
        apks = {arch: a["apk"]["url"] for arch, a in manifest["packages"]["xray-core"]["current"]["assets"].items()}
        self.assertEqual(apks, {"aarch64_generic": "xray-core-1.0-r1_aarch64_generic.apk", "x86_64": "xray-core-1.0-r1_x86_64.apk"})
        self.assertEqual((self.out / apks["x86_64"]).read_bytes(), b"apk:xray-core:1.0-r1:x86_64:x86_64")
        self.assertEqual(manifest["packages"]["aether-proxy"]["current"]["assets"]["all"]["apk"]["url"], "aether-proxy-1.0-r1.apk")
        # data: size/sha256 describe the downloaded .gz, content_sha256 the plain list
        datum = manifest["data"]["gfwlist"]
        compressed = (self.out / datum["url"]).read_bytes()
        self.assertEqual(gzip.decompress(compressed), b"gfwlist\nsecond\n")
        self.assertEqual(datum["sha256"], build.sha256(compressed))
        self.assertEqual(datum["size"], len(compressed))
        self.assertEqual(datum["content_sha256"], build.sha256(gzip.decompress(compressed)))
        self.assertEqual(datum["lines"], 2)

    def test_missing_apk_for_an_architecture_fails(self):
        self.add_packages(packages=("xray-core",))
        (self.packages / "x86_64" / "aetherproxy" / "xray-core-1.0-r1.apk").unlink()
        with self.assertRaisesRegex(ValueError, "missing apk"):
            self.run_build()

    def test_arch_specific_apk_outside_a_target_directory_is_rejected(self):
        (self.packages / "xray-core-1.0-r1.apk").write_bytes(b"x")
        (self.packages / "xray-core_1.0-r1_x86_64.ipk").write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "unplaceable"):
            self.run_build()

    def test_new_version_moves_old_current_to_previous(self):
        old_current = {"version": "0.9-r1", "assets": {"all": {"ipk": {"url": "old.ipk"}}}}
        old_previous = {"version": "0.8-r1", "assets": {}}
        self.add_packages("1.0-r1", packages=("aether-proxy",))
        self.previous({"aether-proxy": {"current": old_current, "previous": old_previous}})
        self.run_build(previous=self.previous_path)
        package = json.loads((self.out / "manifest.json").read_text())["packages"]["aether-proxy"]
        self.assertEqual(package["current"]["version"], "1.0-r1")
        self.assertEqual(package["previous"], old_current)

    def test_same_version_carries_current_and_previous_forward(self):
        old_current = {"version": "1.0-r1", "assets": {"all": {"ipk": {"url": "kept.ipk"}}}}
        old_previous = {"version": "0.9-r1", "assets": {}}
        self.add_packages("1.0-r1", packages=("aether-proxy",))
        self.previous({"aether-proxy": {"current": old_current, "previous": old_previous}})
        self.run_build(previous=self.previous_path)
        package = json.loads((self.out / "manifest.json").read_text())["packages"]["aether-proxy"]
        self.assertEqual(package, {"current": old_current, "previous": old_previous})

    def test_no_data_input_reuses_previous_data(self):
        old_data = {"gfwlist": {"version": "abc", "url": "gfwlist-abc.txt.gz"}}
        self.add_packages(packages=("aether-proxy",))
        self.previous(data=old_data)
        self.run_build(previous=self.previous_path)
        manifest = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(manifest["data"], old_data)

    def test_data_only_release_keeps_previous_packages(self):
        old_packages = {"xray-core": {"current": {"version": "1.0-r1", "assets": {}}, "previous": None}}
        self.add_data()
        self.previous(packages=old_packages)
        build.build_to_dir(self.out, None, self.data, self.previous_path)
        manifest = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(manifest["packages"], old_packages)
        self.assertEqual(sorted(p.name for p in self.out.iterdir() if p.suffix in (".ipk", ".apk")), [])

    def test_data_only_release_without_previous_fails(self):
        self.add_data()
        with self.assertRaises(ValueError):
            build.build_to_dir(self.out, None, self.data, None)

    def test_asset_names_are_github_safe(self):
        # luci.mk versions translations as <date>~<hash>; GitHub would rename "~" on upload.
        feed = self.packages / "x86_64" / "aetherproxy"
        self.add_packages(packages=("aether-proxy", "luci-app-aether-proxy"))
        name = "luci-i18n-aether-proxy-zh-cn"
        for arch in ("aarch64_generic", "x86_64"):
            d = self.packages / arch / "aetherproxy"
            (d / f"{name}_26.287.20981~ba764d5_all.ipk").write_bytes(b"ipk")
            (d / f"{name}-26.287.20981~ba764d5.apk").write_bytes(b"apk")
        self.run_build()
        manifest = json.loads((self.out / "manifest.json").read_text())
        current = manifest["packages"][name]["current"]
        self.assertEqual(current["version"], "26.287.20981~ba764d5")
        urls = [asset["url"] for asset in current["assets"]["all"].values()]
        self.assertEqual(sorted(urls), [f"{name}-26.287.20981.ba764d5.apk", f"{name}_26.287.20981.ba764d5_all.ipk"])
        for url in urls:
            self.assertTrue((self.out / url).is_file())
        self.assertTrue(feed.is_dir())

    def test_identical_content_writes_unchanged_marker(self):
        self.add_packages()
        self.add_data()
        first_out = self.root / "first"
        build.build_to_dir(first_out, self.packages, self.data, None)
        first = json.loads((first_out / "manifest.json").read_text())
        first["generated"] = "2026-01-01T00:00:00Z"
        self.previous(first["packages"], first["data"])
        self.run_build(self.data, self.previous_path)
        self.assertTrue((self.out / "unchanged").is_file())

    def test_unselected_packages_are_ignored_and_reported(self):
        self.add_packages(packages=("aether-proxy",))
        (self.packages / "x86_64" / "aetherproxy" / "unrelated_1_all.ipk").write_bytes(b"ignored")
        ignored = self.run_build()
        self.assertEqual(ignored, ["unrelated_1_all.ipk"])
        self.assertFalse((self.out / "unrelated_1_all.ipk").exists())


class SigningTests(unittest.TestCase):
    def test_sign_verify_and_tamper_rejection(self):
        if not USIGN.is_file():
            self.fail(f"required test usign is missing: {USIGN}")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = root / "manifest.json"
            secret = root / "secret.key"
            public = root / "public.key"
            manifest.write_bytes(b'{"schema":2}\n')
            subprocess.run([str(USIGN), "-G", "-p", str(public), "-s", str(secret)], check=True, capture_output=True)
            env = {**os.environ, "PATH": f"{USIGN.parent}:{os.environ['PATH']}"}
            subprocess.run(
                [str(ROOT / "tools/channel/sign.sh"), str(manifest), str(secret), str(public)],
                check=True, env=env,
            )
            subprocess.run([str(USIGN), "-V", "-q", "-m", str(manifest), "-p", str(public)], check=True)
            manifest.write_bytes(manifest.read_bytes() + b" ")
            result = subprocess.run(
                [str(USIGN), "-V", "-q", "-m", str(manifest), "-p", str(public)],
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
