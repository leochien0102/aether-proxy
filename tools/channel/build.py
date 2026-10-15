#!/usr/bin/env python3
"""Build a signed-channel release directory from packages and rule data."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PACKAGE_NAMES = ("xray-core", "aether-proxy", "luci-app-aether-proxy")
DATA_NAMES = ("gfwlist", "chnlist", "apple", "chnroute4", "gfw_static4")


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
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.suffix not in (".ipk", ".apk"):
            continue
        kind = path.suffix[1:]
        match = None
        for package_name in PACKAGE_NAMES:
            separator = "_" if kind == "ipk" else "-"
            suffix = ".ipk" if kind == "ipk" else ".apk"
            prefix = package_name + separator
            if path.name.startswith(prefix) and path.name.endswith(suffix):
                version_arch = path.name[len(prefix):-len(suffix)]
                version, delimiter, arch = version_arch.partition("_")
                if delimiter and version and arch:
                    match = (package_name, version, arch)
                break
        if match is None:
            if any(path.name.startswith(name + ("_" if kind == "ipk" else "-")) for name in PACKAGE_NAMES):
                raise ValueError(f"malformed {kind} package filename: {path.name}")
            ignored.add(path.name)
            continue
        name, version, arch = match
        content = path.read_bytes()
        slot = parsed.setdefault(name, {}).setdefault(version, {}).setdefault(arch, {})
        if kind in slot:
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
                filename = path.name
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
        metadata[name] = {
            "version": version,
            "url": filename,
            "sha256": content_hash,
            "size": len(content),
            "lines": len(content.splitlines()),
        }
        copied[filename] = compressed
    return metadata, copied


def package_manifest(
    built: dict[str, Any], previous: dict[str, Any] | None,
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    old_packages = previous.get("packages", {}) if previous else {}
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
    package_dir: Path, data_dir: Path | None, previous: dict[str, Any] | None,
) -> tuple[dict[str, Any], dict[str, bytes], list[str]]:
    built_packages, copied, ignored = collect_packages(package_dir)
    packages = package_manifest(built_packages, previous)
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


def build_to_dir(out: Path, packages: Path, data: Path | None, previous_path: Path | None) -> list[str]:
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
    parser.add_argument("--packages", required=True, type=Path)
    parser.add_argument("--data", type=Path)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args(argv)
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
