import copy
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

    def compatibility_fixture(self):
        chain = {"required_steps": ["0.6.4-r1", "0.6.6-r1", "0.6.8-r1"], "steps": []}
        predecessor = "0.6.3-r1"
        for version in chain["required_steps"]:
            assets = {"all": {}}
            for kind in ("ipk", "apk"):
                url = f"bridge-{version}.{kind}"
                content = url.encode()
                (self.root / url).write_bytes(content)
                assets["all"][kind] = {"url": url, "size": len(content), "sha256": build.sha256(content)}
            chain["steps"].append({"version": version, "min_from": predecessor,
                                   "reason": "Updater dependency bridge", "assets": assets})
            predecessor = version
        return {"aether-proxy": chain}

    def test_compatibility_input_copies_and_retains_all_bridge_assets(self):
        self.add_packages("0.6.8-r1", packages=("aether-proxy",))
        compatibility = self.compatibility_fixture()
        path = self.root / "compatibility.json"
        path.write_text(json.dumps(compatibility))
        self.assertEqual(build.main(["--out", str(self.out), "--packages", str(self.packages),
                                     "--compatibility", str(path)]), 0)
        manifest = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(manifest["compatibility"], compatibility)
        for asset in build.compatibility_assets(compatibility):
            self.assertEqual(build.sha256((self.out / asset["url"]).read_bytes()), asset["sha256"])
        self.previous_path.write_text(json.dumps(manifest))
        self.add_data()
        next_out = self.root / "next"
        build.build_to_dir(next_out, None, self.data, self.previous_path)
        self.assertEqual(json.loads((next_out / "manifest.json").read_text())["compatibility"], compatibility)
        # Published bridge bytes stay in the release; metadata keeps them reachable
        # to the publisher's retention scan, even when outside current/previous.
        self.assertFalse(any(next_out.glob("*.ipk")))
        build.build_to_dir(self.root / "same", self.packages, None, self.previous_path)
        self.assertTrue((self.root / "same" / "unchanged").exists())

    def test_compatibility_chain_rejects_invalid_contracts(self):
        valid = self.compatibility_fixture()
        packages = {"aether-proxy": {"current": {"version": "0.6.8-r1"}}}
        build.validate_compatibility(valid, packages)
        mutations = {
            "empty": lambda c: c.update(steps=[]),
            "missing itinerary": lambda c: c.pop("required_steps"),
            "empty itinerary": lambda c: c.update(required_steps=[]),
            "removed and rejoined": lambda c: (c["steps"].pop(1), c["steps"][1].update(min_from="0.6.4-r1")),
            "order": lambda c: c["steps"].reverse(),
            "duplicate": lambda c: c["steps"].insert(1, c["steps"][0]),
            "gap": lambda c: c["steps"][1].update(min_from="0.6.3-r1"),
            "source": lambda c: c.update({"from": "0.6.2-r1"}),
            "reason": lambda c: c["steps"][0].update(reason=" "),
            "assets": lambda c: c["steps"][0].update(assets={}),
            "invalid version": lambda c: c["steps"][0].update(min_from="0.6-rc1"),
            "descending source": lambda c: c["steps"][0].update(min_from="0.6.5-r1"),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                candidate = copy.deepcopy(valid)
                mutate(candidate["aether-proxy"])
                with self.assertRaises(ValueError):
                    build.validate_compatibility(candidate, packages)
        for version in ("0.6.8", "0.6.8-1", "0.6.9-r1"):
            with self.subTest(target=version), self.assertRaisesRegex(ValueError, "terminal"):
                build.validate_compatibility(valid, {"aether-proxy": {"current": {"version": version}}})
        for value in (None, [], {}, {"aether-proxy": []}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                build.validate_compatibility(value, packages)

    def test_compatibility_asset_metadata_rejected(self):
        valid = self.compatibility_fixture()
        packages = {"aether-proxy": {"current": {"version": "0.6.8-r1"}}}
        for key, value in (("url", "../escape.ipk"), ("url", "https://host/file.ipk"),
                           ("url", "bad.apk"), ("sha256", "bad"), ("size", True),
                           ("size", 0), ("size", "20")):
            with self.subTest(key=key, value=value):
                candidate = copy.deepcopy(valid)
                candidate["aether-proxy"]["steps"][0]["assets"]["all"]["ipk"][key] = value
                with self.assertRaises(ValueError):
                    build.validate_compatibility(candidate, packages)

    def test_compatibility_missing_or_corrupt_bytes_fail_before_writing(self):
        self.add_packages("0.6.8-r1", packages=("aether-proxy",))
        compatibility = self.compatibility_fixture()
        path = self.root / "compatibility.json"
        path.write_text(json.dumps(compatibility))
        asset = next(build.compatibility_assets(compatibility))
        (self.root / asset["url"]).write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "hash/size mismatch"):
            build.build_to_dir(self.out, self.packages, None, None, path)
        self.assertFalse(self.out.exists())
        (self.root / asset["url"]).unlink()
        with self.assertRaisesRegex(ValueError, "missing compatibility asset"):
            build.build_to_dir(self.out, self.packages, None, None, path)
        self.assertFalse(self.out.exists())

    def test_compatibility_preservation_refuses_new_target_without_extended_chain(self):
        self.add_packages("0.6.8-r1", packages=("aether-proxy",))
        compatibility = self.compatibility_fixture()
        previous = {"packages": {"aether-proxy": {"current": {"version": "0.6.8-r1"}}},
                    "compatibility": compatibility}
        manifest, _, _ = build.build_manifest(self.packages, None, previous)
        self.assertEqual(manifest["compatibility"], compatibility)
        previous["packages"]["aether-proxy"]["current"]["version"] = "0.6.9-r1"
        with self.assertRaisesRegex(ValueError, "terminal"):
            build.build_manifest(None, None, previous)

    def test_publish_bridge_assets_patch_keeps_historical_steps(self):
        # CHANNEL_ROOT optionally tests the actual external publisher, without modifying it.
        # Otherwise use its frozen URL-enumeration block so this test is portable.
        channel_root = os.environ.get("CHANNEL_ROOT")
        script = self.root / "publisher" / "scripts" / "publish.sh"
        script.parent.mkdir(parents=True)
        if channel_root:
            source = (Path(channel_root) / "scripts" / "publish.sh").read_text()
        else:
            source = '''#!/usr/bin/env bash
python3 - "$work/out/manifest.json" > "$work/urls" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
urls = set()
for entry in m["packages"].values():
    for release in (entry.get("current"), entry.get("previous")):
        for formats in ((release or {}).get("assets") or {}).values():
            urls.update(asset["url"] for asset in formats.values())
urls.update(item["url"] for item in m["data"].values())
print("\\n".join(sorted(urls)))
PY
release_assets | sort > "$work/existing"
'''
        script.write_text(source)
        patch = str(ROOT / "tools/channel/publish-bridge-assets.patch")
        # A deployed publisher already contains the patch. Only patch the frozen/old
        # copy, never the checkout selected by CHANNEL_ROOT.
        deployed = subprocess.run(["git", "apply", "--reverse", "--check", patch],
                                  cwd=script.parent.parent, capture_output=True, text=True)
        if deployed.returncode != 0:
            result = subprocess.run(["git", "apply", patch], cwd=script.parent.parent,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        patched = script.read_text()
        subprocess.run(["bash", "-n", str(script)], check=True)
        enumeration = patched.split('> "$work/urls"', 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        compatibility = self.compatibility_fixture()
        manifest = {"packages": {"aether-proxy": {
            "current": {"assets": {"all": {"ipk": {"url": "current.ipk"}}}},
            "previous": {"assets": {"all": {"ipk": {"url": "previous.ipk"}}}}}},
            "data": {"gfwlist": {"url": "data.gz"}}}
        path = self.root / "manifest.json"
        for with_chain in (False, True):
            if with_chain:
                manifest["compatibility"] = compatibility
            path.write_text(json.dumps(manifest))
            result = subprocess.run(["python3", "-c", enumeration, str(path)],
                                    check=True, capture_output=True, text=True)
            urls = set(result.stdout.splitlines())
            expected = {"current.ipk", "previous.ipk", "data.gz"}
            if with_chain:
                expected.update(asset["url"] for asset in build.compatibility_assets(compatibility))
            self.assertEqual(urls, expected)
            # publish.sh uses this list both for uploads and comm-based deletion.
            existing = expected | {"unreferenced.ipk"}
            self.assertEqual(existing - urls, {"unreferenced.ipk"})

    def test_explicit_null_previous_chain_cannot_silently_enable_direct_update(self):
        for value in (None, {}, [], {"aether-proxy": None}):
            with self.subTest(value=value):
                previous = {"packages": {}, "data": {}, "compatibility": value}
                with self.assertRaises(ValueError):
                    build.build_manifest(None, None, previous)

    def test_compatibility_numeric_versions(self):
        self.assertLess(build.compatibility_version("0.6.9-r2"), build.compatibility_version("0.6.10-1"))
        self.assertLess(build.compatibility_version("0.6.8-r2"), build.compatibility_version("0.6.8-r10"))
        self.assertEqual(build.compatibility_version("0.6.8-1"), build.compatibility_version("0.6.8-r1"))
        for value in ("0.6", "0.6.8-rc1", "0.6.8-r", "v0.6.8", "0.6.8\n", 123):
            with self.subTest(value=value), self.assertRaises(ValueError):
                build.compatibility_version(value)

    def test_complete_manifest_copies_assets_and_computes_data_fields(self):
        self.add_packages()
        self.add_data()
        self.run_build(self.data)
        manifest = json.loads((self.out / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], 2)
        self.assertTrue(manifest["generated"].endswith("Z"))
        self.assertEqual(set(manifest["packages"]), set(build.PACKAGE_NAMES))
        # noarch packages collapse to "all"; aether-xray keeps one entry per target
        self.assertEqual(set(manifest["packages"]["aether-proxy"]["current"]["assets"]), {"all"})
        self.assertEqual(set(manifest["packages"]["aether-xray"]["current"]["assets"]), {"aarch64_generic", "x86_64"})
        self.assertEqual(set(manifest["packages"]["chinadns-ng"]["current"]["assets"]), {"aarch64_generic", "x86_64"})
        asset = manifest["packages"]["aether-proxy"]["current"]["assets"]["all"]["ipk"]
        content = (self.out / asset["url"]).read_bytes()
        self.assertEqual(asset["size"], len(content))
        self.assertEqual(asset["sha256"], build.sha256(content))
        # arch-specific apks get the architecture in the asset name, so targets do not collide
        apks = {arch: a["apk"]["url"] for arch, a in manifest["packages"]["aether-xray"]["current"]["assets"].items()}
        self.assertEqual(apks, {"aarch64_generic": "aether-xray-1.0-r1_aarch64_generic.apk", "x86_64": "aether-xray-1.0-r1_x86_64.apk"})
        self.assertEqual((self.out / apks["x86_64"]).read_bytes(), b"apk:aether-xray:1.0-r1:x86_64:x86_64")
        self.assertEqual(manifest["packages"]["aether-proxy"]["current"]["assets"]["all"]["apk"]["url"], "aether-proxy-1.0-r1.apk")
        # data: size/sha256 describe the downloaded .gz, content_sha256 the plain list
        datum = manifest["data"]["gfwlist"]
        compressed = (self.out / datum["url"]).read_bytes()
        self.assertEqual(gzip.decompress(compressed), b"gfwlist\nsecond\n")
        self.assertEqual(datum["sha256"], build.sha256(compressed))
        self.assertEqual(datum["size"], len(compressed))
        self.assertEqual(datum["content_sha256"], build.sha256(gzip.decompress(compressed)))
        self.assertEqual(datum["lines"], 2)

    def test_aether_xray_multiarch_contract(self):
        self.add_packages("26.10.21-r1", packages=("aether-xray",))
        self.run_build()
        manifest = json.loads((self.out / "manifest.json").read_text())
        self.assertIn("aether-xray", manifest["packages"])
        assets = manifest["packages"]["aether-xray"]["current"]["assets"]
        for arch in ("aarch64_generic", "x86_64"):
            for kind in ("ipk", "apk"):
                separator = "_" if kind == "ipk" else "-"
                filename = f"aether-xray{separator}26.10.21-r1_{arch}.{kind}"
                self.assertEqual(assets[arch][kind]["url"], filename)
                self.assertTrue((self.out / filename).is_file())

    def test_missing_apk_for_an_architecture_fails(self):
        self.add_packages(packages=("aether-xray",))
        (self.packages / "x86_64" / "aetherproxy" / "aether-xray-1.0-r1.apk").unlink()
        with self.assertRaisesRegex(ValueError, "missing apk"):
            self.run_build()

    def test_arch_specific_apk_outside_a_target_directory_is_rejected(self):
        (self.packages / "aether-xray-1.0-r1.apk").write_bytes(b"x")
        (self.packages / "aether-xray_1.0-r1_x86_64.ipk").write_bytes(b"x")
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

    def test_legacy_manifest_keeps_legacy_entry_without_inheriting_its_history(self):
        legacy = {"current": {"version": "99.1-r8", "assets": {}},
                  "previous": {"version": "99.1-r7", "assets": {}}}
        self.previous({"xray-core": legacy})
        self.add_packages("26.10.21-r1", packages=("aether-xray",))
        self.add_packages("100-r1", packages=("xray-core",))
        ignored = self.run_build(previous=self.previous_path)
        manifest = json.loads((self.out / "manifest.json").read_text())
        self.assertEqual(manifest["packages"]["xray-core"], legacy)
        self.assertEqual(manifest["packages"]["aether-xray"]["current"]["version"], "26.10.21-r1")
        self.assertIsNone(manifest["packages"]["aether-xray"]["previous"])
        self.assertEqual(len(ignored), 3)
        self.assertTrue(all(name.startswith("xray-core") for name in ignored))
        self.assertFalse(any(file.name.startswith("xray-core") for file in self.out.iterdir()))

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
