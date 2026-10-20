#!/usr/bin/env python3
"""T9.5: run real probe jobs and count atomic LKG publications with inotify.

Design: docs/03 bootstrap step 3 and docs/07 node reachability probes.
Only loopback TCP and isolated --sys-root files are used.
"""
import ctypes
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

root, temp, open_port, closed_port = sys.argv[1:]
root, temp = Path(root), Path(temp)
temp.mkdir()
bin_dir = temp / "stubs/bin"
bin_dir.mkdir(parents=True)
for name in ("common.sh", "resolveip"):
    shutil.copy2(root / "tests/stubs/bin" / name, bin_dir / name)
sequence = temp / "sequence"
sequence.mkdir()
for i in (1, 2):
    (sequence / f"{i}.rc").write_text("0\n")
    (sequence / f"{i}.out").write_text("127.0.0.1\n")
calls = temp / "calls.log"
(bin_dir.parent / "stub.env").write_text(
    f"STUB_LOG='{calls}'\nSTUB_RESOLVEIP_SEQUENCE='{sequence}'\nSTUB_RESOLVEIP_RC=1\n"
)
conf = temp / "conf"
conf.mkdir()
ids = [f"n_{i:032x}" for i in range(1, 4)]
addresses = ["one.example", "two.example", "failed.example"]
text = "config main 'main'\n\toption enabled '0'\nconfig probe 'probe'\n\toption node_timeout '1'\n"
for node_id, address, port in zip(ids, addresses, [open_port, closed_port, closed_port]):
    text += (
        f"config node '{node_id}'\n\toption protocol 'trojan'\n\toption address '{address}'\n"
        f"\toption port '{port}'\n\toption password 'test'\n\toption security 'tls'\n"
    )
(conf / "aetherproxy").write_text(text)
sysroot = temp / "sysroot"
state_dir = sysroot / "etc/aether-proxy/state"
state_dir.mkdir(parents=True)
(sysroot / "var/run/aether-proxy").mkdir(parents=True)
lkg = state_dir / "node-ip.json"
# Watch the actual target directory, not write_atomic calls: this counts real renames.
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
if fd < 0 or libc.inotify_add_watch(fd, os.fsencode(state_dir), 0x80) < 0:
    raise OSError(ctypes.get_errno(), "inotify setup failed")


def publications():
    count = 0
    while True:
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            return count
        offset = 0
        while offset < len(data):
            _, mask, _, size = struct.unpack_from("iIII", data, offset)
            name = data[offset + 16:offset + 16 + size].split(b"\0")[0]
            if mask & 0x80 and name == b"node-ip.json":
                count += 1
            offset += 16 + size


def probe(selected=()):
    argv = [root / "tests/host/ucode", "-S", root / "aether-proxy/src/aether-proxy", "--",
            "probe", "nodes", *selected, "--json", "--confdir", conf,
            "--sys-root", sysroot, "--bin-dir", bin_dir]
    result = subprocess.run(list(map(str, argv)), capture_output=True, text=True)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    assert not result.stderr, result.stderr
    return json.loads(result.stdout)


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print(f"PASS  {name}", flush=True)


try:
    first = probe()
    check("probe LKG: two resolved domains saved with exactly one atomic publication",
          json.loads(lkg.read_text()) == {"nodes": {"one.example": "127.0.0.1", "two.example": "127.0.0.1"}}
          and publications() == 1)
    check("probe LKG: resolved but TCP-refused node is cached", first["nodes"][ids[1]]["error"] == "refused")
    check("probe LKG: failed DNS is not cached and not retried",
          first["nodes"][ids[2]]["error"] == "resolve_failed" and len(calls.read_text().splitlines()) == 3)
    (sequence / "count").unlink()
    second = probe()
    check("probe LKG: identical second job makes no atomic publication", publications() == 0)
    check("probe LKG: second job still resolves each domain exactly once", len(calls.read_text().splitlines()) == 6)
    # A known LKG must not make a failing live DNS probe look successful.
    cached = json.loads(lkg.read_text())
    cached["nodes"]["failed.example"] = "127.0.0.1"
    lkg.write_text(json.dumps(cached))
    failed = probe([ids[2]])
    check("probe LKG: failed live DNS ignores matching LKG and leaves cache unchanged",
          failed["nodes"][ids[2]]["error"] == "resolve_failed" and failed["nodes"][ids[2]]["ip"] is None
          and json.loads(lkg.read_text()) == cached and publications() == 0
          and len(calls.read_text().splitlines()) == 7)
    # Cache persistence is best-effort; a failed rename must be visible, not hide measurements.
    lkg.unlink()
    lkg.mkdir()
    (sequence / "count").unlink()
    blocked = probe()
    events = (sysroot / "var/run/aether-proxy/events.jsonl").read_text().splitlines()
    check("probe LKG: cache write failure reports FS_FAILED and preserves measured results",
          blocked["finished"] and blocked["nodes"][ids[0]]["ok"] == 3
          and len(events) == 1 and json.loads(events[0])["code"] == "FS_FAILED" and lkg.is_dir()
          and json.loads(events[0])["args"].get("path") == str(lkg))
finally:
    os.close(fd)
