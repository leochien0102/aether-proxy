#!/usr/bin/env python3
"""T9.45: check nft lexer syntax only, never install rules or require root.

The SDK's nft 1.1.6 accepts literal backslashes, not C-style quoted-string escapes.
An unprivileged netlink cache error is NOT a successful kernel ruleset validation.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SDK = Path(os.environ.get(
    "NFT_SDK_ROOT",
    "/workspace/openwrt/sdk-spike/sdk-25.12.5/staging_dir/target-x86_64_musl/root-x86",
))
COMMAND = [
    str(SDK / "lib/ld-musl-x86_64.so.1"),
    "--library-path", str(SDK / "lib") + ":" + str(SDK / "usr/lib"),
    str(SDK / "usr/sbin/nft"),
]
CACHE_ERROR = "netlink: Error: cache initialization failed: Operation not permitted"


def check(path, syntax_error=False):
    result = subprocess.run(COMMAND + ["-c", "-f", str(path)], cwd=ROOT,
                            text=True, capture_output=True, check=False)
    diagnostics = result.stdout + result.stderr
    has_syntax_error = "syntax error" in diagnostics.lower()
    if has_syntax_error != syntax_error:
        raise AssertionError(f"{path}: exit={result.returncode}\n{diagnostics}")
    if not syntax_error and result.returncode != 0:
        # Do not turn missing libraries, signals, or semantic errors into a syntax PASS.
        if result.returncode != 1 or diagnostics.strip() != CACHE_ERROR:
            raise AssertionError(f"unexpected nft failure: {path}\n{diagnostics}")
    if syntax_error and result.returncode == 0:
        raise AssertionError(f"negative control unexpectedly succeeded: {path}")
    status = "syntax error detected" if syntax_error else "no syntax error"
    cache = "; netlink cache unavailable" if CACHE_ERROR in diagnostics else ""
    print(f"PASS {path.name}: {status}; exit={result.returncode}{cache}")


def main():
    version = subprocess.run(COMMAND + ["--version"], cwd=ROOT, text=True,
                             capture_output=True, check=True)
    print(version.stdout.strip())
    probes = [
        ("br-lan", '"br-lan"', False),
        ("eth0.2", '"eth0.2"', False),
        ("one-backslash", '"br-\\lan"', False),
        ("two-backslashes", '"br-\\\\lan"', False),
        ("trailing-backslash", '"lan\\"', False),
        # This passes syntax but denotes literal backslash-x-zero-nine, NOT a tab.
        ("literal-hex-spelling", '"br-\\x09lan"', False),
        ("old-backslash-quote", '"br-\\"lan"', True),
    ]
    with tempfile.TemporaryDirectory(prefix=".t945-nft-", dir=ROOT / "tests/unit") as tmp:
        for name, token, invalid in probes:
            path = Path(tmp) / (name + ".nft")
            path.write_text("table inet aetherproxy_syntax_probe {\n\tchain probe {\n"
                            f"\t\tiifname != {{ {token} }} return\n\t}}\n}}\n")
            check(path, syntax_error=invalid)
    goldens = sorted((ROOT / "tests/fixtures").glob("*/expected/aether-proxy.nft"))
    if not goldens:
        raise AssertionError("no nft golden fixtures")
    for path in goldens:
        print(f"CHECK {path.relative_to(ROOT)}")
        check(path)
    print(f"nft syntax: {len(probes)} probes, {len(goldens)} goldens, 0 failures; no rules loaded")


if __name__ == "__main__":
    main()
