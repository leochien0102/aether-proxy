#!/usr/bin/env python3
"""Build a signed-channel release directory from packages and rule data."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# chinadns-ng is published for manual installation only: devices update just their own
# fixed package list (lib/const.uc UPDATE_PACKAGES) and ignore the other manifest entries.
PACKAGE_NAMES = ("aether-xray", "chinadns-ng", "aether-proxy", "luci-app-aether-proxy", "luci-i18n-aether-proxy-zh-cn")
# Architecture-independent packages: their apk file names carry no architecture at all.
ARCH_ALL = ("aether-proxy", "luci-app-aether-proxy", "luci-i18n-aether-proxy-zh-cn")
DATA_NAMES = ("gfwlist", "chnlist", "apple", "chnroute4", "gfw_static4")


def asset_name(filename: str) -> str:
    # GitHub renames release assets with characters outside this set (the luci-i18n version
    # carries a "~"), so the manifest url would no longer match. opkg/apk read the package
    # metadata, not the file name, so renaming is safe.
    return re.sub(r"[^A-Za-z0-9._-]", ".", filename)


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def read_previous(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read previous manifest {path}: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema") != 2:
        raise ValueError("previous manifest must be a schema 2 object")
    if not isinstance(value.get("packages"), dict) or not isinstance(value.get("data", {}), dict):
        raise ValueError("previous manifest has invalid packages or data")
    return value


def collect_packages(directory: Path) -> tuple[dict[str, Any], dict[str, bytes], list[str]]:
    if not directory.is_dir():
        raise ValueError(f"package directory does not exist: {directory}")

    parsed: dict[str, dict[str, dict[str, dict[str, tuple[Path, bytes]]]]] = {}
    ignored: set[str] = set()
    # Layout as the SDK writes it: <directory>/<target arch>/<feed>/<file>. ipk names carry the
    # package architecture (<name>_<version>_<arch>.ipk, "all" for noarch); apk names from the
    # 25.12 SDK carry none (<name>-<version>.apk), so the architecture comes from ARCH_ALL or the
    # first path component.
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.suffix not in (".ipk", ".apk"):
            continue
        kind = path.suffix[1:]
        rel = path.relative_to(directory)
        arch_dir = rel.parts[0] if len(rel.parts) > 1 else None
        # Longest name first, so "aether-proxy" cannot claim "aether-proxy-…" of another package.
        names = sorted(PACKAGE_NAMES, key=len, reverse=True)
        match = None
        claimed = None
        for package_name in names:
            separator = "_" if kind == "ipk" else "-"
            prefix = package_name + separator
            if not path.name.startswith(prefix):
                continue
            rest = path.name[len(prefix):-len(path.suffix)]
            if kind == "ipk":
                version, delimiter, arch = rest.partition("_")
                if delimiter and version and arch:
                    match = (package_name, version, arch)
            else:
                arch = "all" if package_name in ARCH_ALL else arch_dir
                version = rest
                if arch and arch != "all" and version.endswith("_" + arch):
                    version = version[:-len(arch) - 1]
                if arch and version and "_" not in version:
                    match = (package_name, version, arch)
            claimed = package_name
            break
        if match is None:
            if claimed is not None:
                raise ValueError(f"malformed or unplaceable {kind} package file: {rel}")
            ignored.add(path.name)
            continue
        name, version, arch = match
        content = path.read_bytes()
        slot = parsed.setdefault(name, {}).setdefault(version, {}).setdefault(arch, {})
        if kind in slot:
            # Every target's SDK builds the noarch packages again (bytes may differ by build
            # time); one copy is enough, keep the first in path order.
            if arch == "all":
                continue
            raise ValueError(f"duplicate {kind} package for {name} {version} {arch}")
        slot[kind] = (path, content)

    packages: dict[str, Any] = {}
    copied: dict[str, bytes] = {}
    for name, versions in sorted(parsed.items()):
        if len(versions) != 1:
            raise ValueError(f"{name}: expected one version across package artifacts, found {', '.join(sorted(versions))}")
        version, architectures = next(iter(versions.items()))
        assets: dict[str, Any] = {}
        for arch, formats in sorted(architectures.items()):
            if set(formats) != {"ipk", "apk"}:
                missing = " and ".join(sorted({"ipk", "apk"} - formats.keys()))
                raise ValueError(f"{name} {version} {arch}: missing {missing}")
            assets[arch] = {}
            for kind in ("ipk", "apk"):
                path, content = formats[kind]
                # Release assets are flat: give arch-specific apks the architecture in the name,
                # otherwise every target's aether-xray-<version>.apk would collide.
                filename = asset_name(path.name if kind == "ipk" or arch == "all" else f"{name}-{version}_{arch}.apk")
                if filename in copied and copied[filename] != content:
                    raise ValueError(f"conflicting package asset filename: {filename}")
                copied[filename] = content
                assets[arch][kind] = {"url": filename, "sha256": sha256(content), "size": len(content)}
        packages[name] = {"version": version, "assets": assets}
    return packages, copied, sorted(ignored)


def gzip_data(data: bytes) -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", filename="", mtime=0) as stream:
        stream.write(data)
    return buffer.getvalue()


def collect_data(directory: Path) -> tuple[dict[str, Any], dict[str, bytes]]:
    if not directory.is_dir():
        raise ValueError(f"data directory does not exist: {directory}")
    metadata: dict[str, Any] = {}
    copied: dict[str, bytes] = {}
    for name in DATA_NAMES:
        path = directory / f"{name}.txt"
        if not path.is_file():
            raise ValueError(f"missing data file: {path.name}")
        content = path.read_bytes()
        content_hash = sha256(content)
        version = content_hash[:12]
        filename = f"{name}-{version}.txt.gz"
        compressed = gzip_data(content)
        # size/sha256 describe the downloaded .gz (checked like any asset, 08 "下载");
        # content_sha256 is the plain list, compared with the device's local copy.
        metadata[name] = {
            "version": version,
            "url": filename,
            "sha256": sha256(compressed),
            "size": len(compressed),
            "content_sha256": content_hash,
            "lines": len(content.splitlines()),
        }
        copied[filename] = compressed
    return metadata, copied


def package_manifest(
    built: dict[str, Any], previous: dict[str, Any] | None,
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    old_packages = previous.get("packages", {}) if previous else {}
    # B24: old clients still read this entry. Carry its signed metadata unchanged;
    # never rebuild it or use its version/history for the newly named package.
    if "xray-core" in old_packages:
        result["xray-core"] = old_packages["xray-core"]
    for name, current in sorted(built.items()):
        old = old_packages.get(name, {})
        old_current = old.get("current") if isinstance(old, dict) else None
        old_previous = old.get("previous") if isinstance(old, dict) else None
        if isinstance(old_current, dict) and old_current.get("version") == current["version"]:
            result[name] = {"current": old_current, "previous": old_previous}
        else:
            result[name] = {
                "current": {"version": current["version"], "assets": current["assets"]},
                "previous": old_current if isinstance(old_current, dict) else None,
            }
    return result


def build_manifest(
    package_dir: Path | None, data_dir: Path | None, previous: dict[str, Any] | None,
) -> tuple[dict[str, Any], dict[str, bytes], list[str]]:
    if package_dir is not None:
        built_packages, copied, ignored = collect_packages(package_dir)
        packages = package_manifest(built_packages, previous)
    else:
        # Data-only release (the daily data job builds no packages): keep the package entries,
        # whose assets are already in the release.
        if previous is None:
            raise ValueError("a release without --packages needs --previous")
        packages, copied, ignored = previous["packages"], {}, []
    if data_dir is not None:
        data, data_files = collect_data(data_dir)
        copied.update(data_files)
    else:
        data = previous.get("data", {}) if previous else {}
    manifest = {
        "schema": 2,
        "generated": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "packages": packages,
        "data": data,
    }
    return manifest, copied, ignored


def canonical_manifest(manifest: dict[str, Any]) -> bytes:
    return (json.dumps(manifest, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def build_to_dir(out: Path, packages: Path | None, data: Path | None, previous_path: Path | None) -> list[str]:
    previous = read_previous(previous_path)
    manifest, copied, ignored = build_manifest(packages, data, previous)
    manifest_path = out / "manifest.json"
    unchanged = False
    if previous is not None:
        old = {key: value for key, value in previous.items() if key != "generated"}
        current = {key: value for key, value in manifest.items() if key != "generated"}
        unchanged = old == current

    # Validate and construct everything before touching the destination.
    out.mkdir(parents=True, exist_ok=True)
    for filename, content in copied.items():
        (out / filename).write_bytes(content)
    manifest_path.write_bytes(canonical_manifest(manifest))
    marker = out / "unchanged"
    if unchanged:
        marker.write_text("\n", encoding="utf-8")
    elif marker.exists():
        marker.unlink()
    return ignored


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--packages", type=Path)
    parser.add_argument("--data", type=Path)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args(argv)
    if args.packages is None and args.data is None:
        parser.error("nothing to build: give --packages and/or --data")
    try:
        ignored = build_to_dir(args.out, args.packages, args.data, args.previous)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print(f"channel build failed: {exc}", file=sys.stderr)
        return 1
    for filename in ignored:
        print(f"ignored package: {filename}")
    print(f"manifest.json: {args.out / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
