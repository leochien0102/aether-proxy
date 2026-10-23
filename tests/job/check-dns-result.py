#!/usr/bin/env python3
"""Check real DNS-job output against the direct CLI and docs/03's unsupported row."""

import json
import sys
from pathlib import Path


def main():
    direct_path, job_path = map(Path, sys.argv[1:])
    direct = json.loads(direct_path.read_text())
    job = json.loads(job_path.read_text())
    expected = {
        "ok": True,
        "results": [{
            "upstream": "tls://127.0.0.1#853",
            "unblocked": {
                "domain": "www.microsoft.com", "ok": 0, "total": 3, "latency_ms": None,
            },
            "blocked": {
                "domain": "www.google.com", "ok": 0, "total": 3, "latency_ms": None,
            },
            "unsupported": True,
        }],
    }
    assert direct == expected, f"unexpected direct CLI result: {direct!r}"
    assert job["kind"] == "dns_test", job
    assert job["state"] == "ok" and job["exit"] == 0 and job["error"] is None, job
    assert job["result"] == direct, f"job changed the CLI result: {job!r}"
    # Only jobs survive this loopback-only run; private UCI savedirs must be removed.
    remaining_dirs = [p.name for p in job_path.parent.parent.iterdir() if p.is_dir()]
    assert remaining_dirs == ["jobs"], f"private UCI savedir leaked: {remaining_dirs!r}"


if __name__ == "__main__":
    main()
