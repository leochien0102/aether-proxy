#!/usr/bin/env python3
"""Manual host check: can dnsmasq replace ChinaDNS-NG? (docs/03 "替换 ChinaDNS-NG")

Not part of tests/run.uc: it needs a host build of dnsmasq, which CI does not have.
It starts throwaway dnsmasq instances on loopback ports with fake upstreams and
asserts the behaviours the design depends on. Every run prints the measured
startup time / RSS / latency so the numbers in docs/03 can be re-derived.

Usage:
    make -C <dnsmasq source>            # or point DNSMASQ_BIN at an installed dnsmasq
    DNSMASQ_BIN=/path/to/dnsmasq python3 tests/dns/check.py
"""

import os
import random
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time

BIN = os.environ.get("DNSMASQ_BIN") or shutil.which("dnsmasq")
if not BIN:
    raise SystemExit("set DNSMASQ_BIN to a dnsmasq >= 2.90 binary (needs --filter-rr)")

PORT = 15900
WORK = tempfile.mkdtemp(prefix="dnscheck-")
FAILS = []


def ok(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")
    if not cond:
        FAILS.append(name)


# ---------------------------------------------------------------- DNS plumbing
def enc(name):
    return b"".join(bytes([len(x)]) + x.encode() for x in name.strip(".").split(".")) + b"\0"


def parse(pkt):
    rcode = pkt[3] & 0x0F
    qd, an = struct.unpack("!HH", pkt[4:8])
    off = 12
    for _ in range(qd):
        while pkt[off]:
            off += pkt[off] + 1
        off += 5
    rrs = []
    for _ in range(an):
        off += 2 if pkt[off] & 0xC0 else 0
        rtype, _cls, _ttl, rdlen = struct.unpack("!HHIH", pkt[off:off + 10])
        off += 10
        rrs.append((rtype, pkt[off:off + rdlen]))
        off += rdlen
    return rcode, rrs


def answer(q, ip, ttl=60):
    off = 12
    while q[off]:
        off += q[off] + 1
    off += 1
    qtype = struct.unpack("!H", q[off:off + 2])[0]
    question = q[12:off + 4]
    body, an = b"", 0
    if qtype == 1:
        body = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, ttl, 4) + socket.inet_aton(ip)
        an = 1
    elif qtype == 28:
        body = b"\xc0\x0c" + struct.pack("!HHIH", 28, 1, ttl, 16) + socket.inet_pton(
            socket.AF_INET6, "fd00::1")
        an = 1
    elif qtype == 65:  # HTTPS RR, priority=1 target=.
        rdata = b"\x00\x01\x00"
        body = b"\xc0\x0c" + struct.pack("!HHIH", 65, 1, ttl, len(rdata)) + rdata
        an = 1
    return q[:2] + struct.pack("!HHHHH", 0x8180, 1, an, 0, 0) + question + body


def upstream(port, ip, delay=0.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    while True:
        pkt, addr = s.recvfrom(4096)
        if delay:
            time.sleep(delay)
        s.sendto(answer(pkt, ip), addr)


def query(name, qtype=1, timeout=15.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(struct.pack("!HHHHHH", random.randrange(65536), 0x0100, 1, 0, 0, 0)
             + enc(name) + struct.pack("!HH", qtype, 1), ("127.0.0.1", PORT))
    t0 = time.time()
    try:
        pkt, _ = s.recvfrom(4096)
    except socket.timeout:
        return None
    finally:
        s.close()
    rcode, rrs = parse(pkt)
    return {"rcode": rcode, "an": len(rrs), "ms": (time.time() - t0) * 1000,
            "ips": [socket.inet_ntoa(rd) for t, rd in rrs if t == 1 and len(rd) == 4]}


def free(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def rss(pid):
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return -1


def run(conf_lines, extra=()):
    conf = os.path.join(WORK, "d.conf")
    with open(conf, "w") as f:
        f.write("\n".join(conf_lines) + "\n")
    assert free(PORT), f"port {PORT} busy"
    log = open(os.path.join(WORK, "dnsmasq.log"), "w")
    p = subprocess.Popen([BIN, "--keep-in-foreground", "--no-daemon", f"--conf-file={conf}",
                          f"--port={PORT}", "--listen-address=127.0.0.1",
                          "--bind-interfaces", "--no-hosts",
                          f"--pid-file={WORK}/d.pid", *extra],
                         stdout=log, stderr=subprocess.STDOUT)
    t0 = time.time()
    while time.time() - t0 < 60:
        if p.poll() is not None:
            raise SystemExit("dnsmasq exited:\n" + open(log.name).read()[-2000:])
        r = query("probe.local", timeout=0.1)
        if r is not None:
            break
        time.sleep(0.01)
    startup = (time.time() - t0) * 1000
    time.sleep(0.1)
    return p, startup


def stop(p):
    p.send_signal(signal.SIGTERM)
    p.wait(timeout=10)


def domains(n, seed=7):
    rnd = random.Random(seed)
    words = ["alpha", "beta", "gamma", "delta", "omega", "sigma", "kappa", "zeta"]
    out = set()
    while len(out) < n:
        out.add(f"{rnd.choice(words)}{rnd.randrange(1000000)}.cn")
    return sorted(out)


def main():
    print(f"dnsmasq: {BIN}")
    version = subprocess.run([BIN, "--version"], capture_output=True, text=True)
    print(f"version: {(version.stdout or version.stderr).strip().splitlines()[0]}")
    china, trust, direct = PORT + 2, PORT + 3, PORT + 4
    for port, ip in ((china, "10.0.0.1"), (trust, "8.8.8.8"), (direct, "9.9.9.9")):
        threading.Thread(target=upstream, args=(port, ip), daemon=True).start()
    time.sleep(0.2)

    # --- semantics ----------------------------------------------------------
    p, startup = run([
        "no-resolv", "cache-size=4096",
        f"server=127.0.0.1#{china}",
        f"server=/gfw.test/127.0.0.1#{trust}",
        f"server=/api.openai.com/127.0.0.1#{trust}",
        f"server=/openai.com/127.0.0.1#{china}",
        f"server=/node.boot.test/127.0.0.1#{direct}",
        "filter-rr=AAAA,HTTPS",
    ])
    print(f"-- startup {startup:.0f} ms, RSS {rss(p.pid)} kB")
    ok("default domain uses china upstream", query("example.com")["ips"] == ["10.0.0.1"])
    ok("suffix match on gfw.test", query("www.gfw.test")["ips"] == ["8.8.8.8"])
    ok("parent domain itself matches", query("gfw.test")["ips"] == ["8.8.8.8"])
    ok("supergfw.test does not match /gfw.test/", query("supergfw.test")["ips"] == ["10.0.0.1"])
    ok("more specific api.openai.com wins", query("api.openai.com")["ips"] == ["8.8.8.8"])
    ok("parent openai.com still china", query("openai.com")["ips"] == ["10.0.0.1"])
    ok("boot domain uses direct upstream", query("node.boot.test")["ips"] == ["9.9.9.9"])
    ok("AAAA stripped (upstream answered it)", query("www.gfw.test", 28)["an"] == 0)
    ok("HTTPS(65) stripped", query("www.gfw.test", 65)["an"] == 0)
    ok("A untouched", query("www.gfw.test", 1)["an"] == 1)
    stop(p)

    # --- scale --------------------------------------------------------------
    for n in (4300, 109893):
        doms = domains(n)
        lines = ["no-resolv", "cache-size=4096", f"server=127.0.0.1#{china}"]
        lines += [f"server=/{d}/127.0.0.1#{trust}" for d in doms]
        conf_size = len("\n".join(lines)) / 1048576
        p, startup = run(lines)
        mem = rss(p.pid)
        sample = random.sample(doms, 200)
        lat, good = [], 0
        for d in sample:
            r = query(d)
            lat.append(r["ms"])
            good += 1 if r["ips"] == ["8.8.8.8"] else 0
        lat.sort()
        print(f"-- n={n:6d} conf={conf_size:5.2f} MiB startup={startup:6.0f} ms "
              f"rss={mem:6d} kB p50={lat[len(lat)//2]:.2f} ms ok={good}/{len(sample)}")
        ok(f"{n} server= lines all route correctly", good == len(sample))
        stop(p)

    # --- dead upstream + group failover -------------------------------------
    dead = PORT + 90
    p, _ = run(["no-resolv", "cache-size=0",
                f"server=127.0.0.1#{china}",
                f"server=/dead.test/127.0.0.1#{dead}"])
    threading.Thread(target=lambda: query("x.dead.test", timeout=12), daemon=True).start()
    time.sleep(0.3)
    ok("hanging domain does not block others", query("example.com")["ms"] < 100)
    stop(p)
    p, _ = run(["no-resolv", "cache-size=0",
                f"server=/grp.test/127.0.0.1#{dead}",
                f"server=/grp.test/127.0.0.1#{trust}"])
    ok("dead server in a group fails over immediately",
       query("a.grp.test")["ips"] == ["8.8.8.8"])
    stop(p)

    # --- preference: default is RTT, --strict-order is declaration order ----
    fast, slow = PORT + 5, PORT + 6
    threading.Thread(target=upstream, args=(fast, "10.0.0.2", 0), daemon=True).start()
    threading.Thread(target=upstream, args=(slow, "10.0.0.1", 0.05), daemon=True).start()
    time.sleep(0.2)
    p, _ = run(["no-resolv", "cache-size=0",
                f"server=/g.test/127.0.0.1#{slow}",
                f"server=/g.test/127.0.0.1#{fast}"])
    ok("default picks the fastest server (RTT)", query("a.g.test")["ips"] == ["10.0.0.2"])
    stop(p)
    p, _ = run(["no-resolv", "cache-size=0", "strict-order",
                f"server=/g.test/127.0.0.1#{slow}",
                f"server=/g.test/127.0.0.1#{fast}"])
    ok("--strict-order picks the first server", query("a.g.test")["ips"] == ["10.0.0.1"])
    stop(p)

    print()
    if FAILS:
        print(f"FAILED {len(FAILS)}: {', '.join(FAILS)}")
        raise SystemExit(1)
    print("all dnsmasq checks passed")


if __name__ == "__main__":
    main()
