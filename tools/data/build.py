#!/usr/bin/env python3
"""Build and validate rule-data baselines per docs/08-updates.md data formats and sources."""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


SOURCES = {
    "gfwlist.b64": "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt",
    "china-domains.conf": "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf",
    "apple-domains.conf": "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/apple.china.conf",
    "delegated-apnic-latest": "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest",
    "telegram-cidr.txt": "https://core.telegram.org/resources/cidr.txt",
}

OUTPUT_SOURCES = {
    "gfwlist.txt": ("gfwlist.b64", "LGPL-2.1"),
    "chnlist.txt": ("china-domains.conf", "WTFPL"),
    "apple.txt": ("apple-domains.conf", "WTFPL"),
    "chnroute4.txt": (
        "delegated-apnic-latest",
        "Public registration data; redistribution with packages allowed by docs/08-updates.md",
    ),
    "gfw_static4.txt": (
        "telegram-cidr.txt",
        "Factual IP address list; redistribution with packages allowed by docs/08-updates.md",
    ),
}

# Built in per docs/08: IP-pinned DoH/DoT bypasses DNS-based gfw4 population.
PUBLIC_DNS4 = (
    "8.8.8.8",
    "8.8.4.4",
    "1.1.1.1",
    "1.0.0.1",
    "9.9.9.9",
    "149.112.112.112",
    "208.67.222.222",
    "208.67.220.220",
)

MIN_LINES = {
    "gfwlist.txt": 3000,
    "chnlist.txt": 50000,
    "apple.txt": 50,
    "chnroute4.txt": 3000,
}


def valid_domain(value: str) -> bool:
    if not value or len(value) > 253:
        return False
    for label in value.split("."):
        if not label or len(label) > 63:
            return False
        if re.fullmatch(r"[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?", label) is None:
            return False
    return True


def normalize_domain(value: str) -> str | None:
    domain = value.strip().lower().strip(".")
    if not valid_domain(domain):
        return None
    try:
        ipaddress.ip_address(domain)
    except ValueError:
        return domain
    return None


def gfwlist_domains(decoded: str) -> tuple[list[str], dict[str, int]]:
    domains: set[str] = set()
    skipped: dict[str, int] = {}

    def skip(reason: str) -> None:
        skipped[reason] = skipped.get(reason, 0) + 1

    for raw in decoded.splitlines():
        rule = raw.strip()
        if not rule:
            continue
        if rule.startswith("!"):
            skip("comment")
            continue
        if rule.startswith("[AutoProxy"):
            skip("header")
            continue
        if rule.startswith("@@"):
            skip("whitelist")
            continue
        if rule.startswith("/") and rule.endswith("/"):
            skip("regex")
            continue

        candidate: str
        if rule.startswith("||"):
            candidate = rule[2:]
        elif rule.startswith("|http://") or rule.startswith("|https://"):
            parsed = urlsplit(rule.lstrip("|").rstrip("|"))
            candidate = parsed.hostname or ""
        elif rule.startswith("."):
            candidate = rule.lstrip(".")
        else:
            candidate = rule.lstrip("|")
            if candidate.startswith(("http://", "https://")):
                candidate = urlsplit(candidate).hostname or ""

        candidate = re.split(r"[/^?#]", candidate, maxsplit=1)[0]
        if "*" in candidate:
            skip("wildcard")
            continue
        candidate = candidate.rstrip("|")
        try:
            ipaddress.ip_address(candidate)
        except ValueError:
            pass
        else:
            skip("ip_address")
            continue

        domain = normalize_domain(candidate)
        if domain is None:
            skip("invalid_domain")
        elif domain in domains:
            skip("duplicate")
        else:
            domains.add(domain)

    return sorted(domains), dict(sorted(skipped.items()))


def china_domains(text: str) -> list[str]:
    domains: set[str] = set()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("server=/"):
            raise ValueError(f"china list line {number}: expected server=/domain/address")
        fields = line.split("/")
        if len(fields) < 3 or fields[0] != "server=" or not fields[2]:
            raise ValueError(f"china list line {number}: malformed server rule")
        domain = normalize_domain(fields[1])
        if domain is None:
            raise ValueError(f"china list line {number}: invalid domain {fields[1]!r}")
        domains.add(domain)
    return sorted(domains)


def summarize_range(start: str, count: int) -> list[ipaddress.IPv4Network]:
    first = int(ipaddress.IPv4Address(start))
    if count <= 0 or first + count - 1 > 0xFFFFFFFF:
        raise ValueError(f"invalid APNIC IPv4 allocation: {start} count {count}")
    last = ipaddress.IPv4Address(first + count - 1)
    return list(ipaddress.summarize_address_range(ipaddress.IPv4Address(first), last))


def apnic_networks(text: str) -> list[ipaddress.IPv4Network]:
    ranges: list[ipaddress.IPv4Network] = []
    for number, raw in enumerate(text.splitlines(), 1):
        fields = raw.strip().split("|")
        if len(fields) < 5 or fields[0:3] != ["apnic", "CN", "ipv4"]:
            continue
        try:
            ranges.extend(summarize_range(fields[3], int(fields[4])))
        except (ValueError, ipaddress.AddressValueError) as exc:
            raise ValueError(f"APNIC line {number}: {exc}") from exc

    if not ranges:
        raise ValueError("APNIC source contains no CN IPv4 allocations")
    collapsed = ipaddress.collapse_addresses(ranges)
    return sorted(collapsed, key=lambda net: (int(net.network_address), net.prefixlen))


def static_networks(text: str) -> list[ipaddress.IPv4Network]:
    networks = {ipaddress.IPv4Network(address) for address in PUBLIC_DNS4}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            network = ipaddress.ip_network(line, strict=True)
        except ValueError as exc:
            raise ValueError(f"static CIDR line {number}: {exc}") from exc
        if not isinstance(network, ipaddress.IPv4Network):
            raise ValueError(f"static CIDR line {number}: IPv6 is not supported")
        networks.add(network)
    collapsed = ipaddress.collapse_addresses(networks)
    return sorted(collapsed, key=lambda net: (int(net.network_address), net.prefixlen))


def cidr_lines(networks: list[ipaddress.IPv4Network]) -> list[str]:
    return [
        str(net.network_address) if net.prefixlen == 32 else str(net)
        for net in networks
    ]


def has_address(networks: list[ipaddress.IPv4Network], address: str) -> bool:
    target = ipaddress.IPv4Address(address)
    return any(target in network for network in networks)


def validate_outputs(
    outputs: dict[str, list[str]], minimums: dict[str, int] | None = None,
) -> None:
    for filename, minimum in (MIN_LINES if minimums is None else minimums).items():
        if len(outputs[filename]) < minimum:
            raise ValueError(f"{filename}: {len(outputs[filename])} lines, expected at least {minimum}")

    for filename, required in (("gfwlist.txt", "google.com"), ("chnlist.txt", "baidu.com")):
        if required not in outputs[filename]:
            raise ValueError(f"{filename}: required domain {required} is missing")
    if not any(domain.endswith(".apple.com") for domain in outputs["apple.txt"]):
        raise ValueError("apple.txt: expected at least one subdomain ending in .apple.com")

    routes = [ipaddress.ip_network(line, strict=True) for line in outputs["chnroute4.txt"]]
    for address in ("223.5.5.5", "114.114.114.114"):
        if not has_address(routes, address):
            raise ValueError(f"chnroute4.txt: must cover {address}")
    for address in ("8.8.8.8", "1.1.1.1"):
        if has_address(routes, address):
            raise ValueError(f"chnroute4.txt: must not cover {address}")

    static = [ipaddress.ip_network(line, strict=True) for line in outputs["gfw_static4.txt"]]
    for address in PUBLIC_DNS4:
        if not has_address(static, address):
            raise ValueError(f"gfw_static4.txt: must cover {address}")


def render_sources(
    raw: dict[str, bytes], metadata: dict[str, dict[str, str]],
    outputs: dict[str, list[str]], skipped: dict[str, int],
) -> str:
    rows = [
        "# Rule-data baseline sources",
        "",
        "| Output | Upstream URL | Downloaded (UTC) | Raw SHA-256 | License / terms | Generated lines |",
        "|---|---|---|---|---|---:|",
    ]
    for output, (source, license_name) in OUTPUT_SOURCES.items():
        timestamp = metadata[source]["downloaded_at"]
        checksum = hashlib.sha256(raw[source]).hexdigest()
        rows.append(
            f"| `{output}` | {SOURCES[source]} | {timestamp} | `{checksum}` | "
            f"{license_name} | {len(outputs[output])} |"
        )
    rows.extend(["", "## gfwlist skipped-entry counts", ""])
    if skipped:
        rows.extend(f"- `{reason}`: {count}" for reason, count in sorted(skipped.items()))
    else:
        rows.append("- None")
    rows.append("")
    return "\n".join(rows)


def build_outputs(
    raw: dict[str, bytes], static_source: bytes, metadata: dict[str, dict[str, str]],
    minimums: dict[str, int] | None = None,
) -> dict[str, bytes]:
    try:
        decoded = base64.b64decode(raw["gfwlist.b64"]).decode("utf-8", "replace")
    except (KeyError, ValueError) as exc:
        raise ValueError(f"cannot decode gfwlist base64: {exc}") from exc

    gfw_domains, skipped = gfwlist_domains(decoded)
    outputs: dict[str, list[str]] = {
        "gfwlist.txt": gfw_domains,
        "chnlist.txt": china_domains(raw["china-domains.conf"].decode("utf-8-sig")),
        "apple.txt": china_domains(raw["apple-domains.conf"].decode("utf-8-sig")),
        "chnroute4.txt": cidr_lines(apnic_networks(raw["delegated-apnic-latest"].decode("ascii"))),
        "gfw_static4.txt": cidr_lines(static_networks(static_source.decode("utf-8-sig"))),
    }
    validate_outputs(outputs, minimums)
    files = {
        name: ("\n".join(lines) + "\n").encode("utf-8")
        for name, lines in outputs.items()
    }
    files["SOURCES.md"] = render_sources(raw, metadata, outputs, skipped).encode("utf-8")
    return files


def download_source(name: str, url: str, cache: Path | None) -> tuple[bytes, dict[str, str]]:
    if cache is not None:
        data_path = cache / name
        metadata_path = cache / f"{name}.json"
        if data_path.is_file():
            data = data_path.read_bytes()
            if metadata_path.is_file():
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            else:
                metadata = {"downloaded_at": "unknown (pre-existing cache)"}
            return data, metadata

    request = urllib.request.Request(url, headers={"User-Agent": "aether-proxy-data-builder/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"download failed for {url}: {exc}") from exc

    timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    metadata = {"downloaded_at": timestamp}
    if cache is not None:
        cache.mkdir(parents=True, exist_ok=True)
        data_path = cache / name
        metadata_path = cache / f"{name}.json"
        data_path.write_bytes(data)
        metadata_path.write_text(json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8")
    return data, metadata


def write_baseline(
    out_dir: Path, raw: dict[str, bytes], static_source: bytes,
    metadata: dict[str, dict[str, str]],
) -> dict[str, bytes]:
    generated = build_outputs(raw, static_source, metadata)
    out_dir.mkdir(parents=True, exist_ok=True)
    for filename, content in generated.items():
        (out_dir / filename).write_bytes(content)
    return generated


def build_to_dir(out_dir: Path, static_path: Path, cache_dir: Path | None) -> dict[str, int]:
    raw: dict[str, bytes] = {}
    metadata: dict[str, dict[str, str]] = {}
    for name, url in SOURCES.items():
        raw[name], metadata[name] = download_source(name, url, cache_dir)

    if not static_path.is_file():
        raise RuntimeError(f"required static source file is missing: {static_path}")
    static_source = static_path.read_bytes()

    # All parsing and sanity checks complete before the output directory is created.
    generated = write_baseline(out_dir, raw, static_source, metadata)
    return {
        filename: content.count(b"\n")
        for filename, content in generated.items()
        if filename.endswith(".txt")
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="output directory")
    parser.add_argument("--cache", type=Path, help="cache directory for upstream raw files")
    args = parser.parse_args(argv)

    static_path = Path(__file__).with_name("gfw_static4.src.txt")
    try:
        counts = build_to_dir(args.out, static_path, args.cache)
    except (OSError, UnicodeError, ValueError, RuntimeError, KeyError, json.JSONDecodeError) as exc:
        print(f"data build failed: {exc}", file=sys.stderr)
        return 1

    for filename, count in counts.items():
        size = (args.out / filename).stat().st_size
        print(f"{filename}: {count} lines, {size} bytes")
    print(f"SOURCES.md: {(args.out / 'SOURCES.md').stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
