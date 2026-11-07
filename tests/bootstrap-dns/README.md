# T15.4 explicit private DNS tests

Run from the repository root:

```sh
bash tests/bootstrap-dns/run.sh
python3 tests/bootstrap-dns/mutations.py
bash tests/bootstrap-dns/run.sh
```

`run.sh` executes Q1–Q11 with the actual `aetherproxy.bootstrap_dns` and
`apply.resolve_node_explicit` modules in the pinned host ucode. An optional `Q1`
through `Q11` argument selects a group for diagnosis. Pure validation/selection
cases are also automatically discovered by `tests/run.uc`.

Python only implements a controlled authority and assertions. Every DNS decoder,
CNAME traversal, deadline, retry and LKG decision under test runs in ucode.
Authorities bind dynamically allocated loopback UDP/TCP ports; no host DNS,
resolver command, privileged service, bootstrap engine child or system UCI is used.
The driver registers a real uloop SIGTERM callback. Cancellation tests deliver
SIGTERM to that driver, not to a mock callback. FD counts warm caller-owned
uloop/syslog resources before measuring, then require exact stability.

Each assertion prints its Q identifier. TCP cases split prefix/body, exercise the
65535-byte limit, malformed lengths, EOF, queued surplus data and TC. CNAME cases
include reversed answer order, unrelated and additional A records, same-endpoint
follow-ups, per-lookup limits and cycles. Nine-second and three-second checks use
production defaults; shorter tests use only the public bounded timeout argument.

`mutations.py` edits only the two allowed production modules, one change at a time,
requires the exact intended failing assertion, and restores the original bytes in
`finally`. **Do not run it concurrently with other tests or editors.** Always run
the full suite after mutation restoration. Runtime directories and optional local
logs are ignored; they are not production cache/evidence files.

The authority's response builder is deliberately a scenario dispatch longer than
100 lines: each branch constructs a distinct adversarial packet, keeping the wire
layout and the reason for each malformed response together. It does not decode
responses or replace the tested implementation.

These tests do not prove endpoint child ownership, real-engine TLS PKI, production
readiness/start ordering, or a device startup fix. Those remain separate work.
