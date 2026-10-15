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

    def add_packages(self, version="1.0-r1", arch="all", packages=None):
        names = packages or ("xray-core", "aether-proxy", "luci-app-aether-proxy")
        for name in names:
            (self.packages / f"{name}_{version}_{arch}.ipk").write_bytes(f"ipk:{name}:{version}:{arch}".encode())
            (self.packages / f"{name}-{version}_{arch}.apk").write_bytes(f"apk:{name}:{version}:{arch}".encode())

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
        self.add_packages("1.0-r1", "aarch64_generic", packages=("aether-proxy",))
        self.add_data()
        self.run_build(self.data)
        manifest = json.loads((self.out / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], 2)
        self.assertTrue(manifest["generated"].endswith("Z"))
        self.assertEqual(set(manifest["packages"]), set(build.PACKAGE_NAMES))
        self.assertEqual(
            set(manifest["packages"]["aether-proxy"]["current"]["assets"]),
            {"all", "aarch64_generic"},
        )
        asset = manifest["packages"]["aether-proxy"]["current"]["assets"]["all"]["ipk"]
        content = (self.out / asset["url"]).read_bytes()
        self.assertEqual(asset["size"], len(content))
        self.assertEqual(asset["sha256"], build.sha256(content))
        datum = manifest["data"]["gfwlist"]
        compressed = (self.out / datum["url"]).read_bytes()
        self.assertEqual(gzip.decompress(compressed), b"gfwlist\nsecond\n")
        self.assertEqual(datum["sha256"], build.sha256(gzip.decompress(compressed)))
        self.assertEqual(datum["size"], len(gzip.decompress(compressed)))
        self.assertEqual(datum["lines"], 2)

    def test_missing_apk_for_an_architecture_fails(self):
        self.add_packages(packages=("aether-proxy",))
        (self.packages / "aether-proxy-1.0-r1_all.apk").unlink()
        with self.assertRaisesRegex(ValueError, "missing apk"):
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
        (self.packages / "unrelated_1_all.ipk").write_bytes(b"ignored")
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
