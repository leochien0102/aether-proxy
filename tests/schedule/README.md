# Schedule integration fixtures

Formal entry (run from the repository root):

```sh
bash tests/schedule/run.sh
```

The business summary is **47 passed, 0 failed**. Pure-function scripts also print
PASS lines; those are not additional entries in this summary.

The real daemon runs against a synthetic sys-root/proc fixture. Private bootstrap
UDP/TCP query sockets are real loopback sockets; ownership tables are explicitly
synthetic and ELF identification is seeded by `tests/xray-ready/proc_fixture.py`.
This is not a device/network-environment acceptance test.

- `SCHEDULE_RESOLVE_FAIL` defaults to `1`. `start_daemon` maps the same intention
  to B3's `resolve-always-fail` control and retains `STUB_RESOLVE_FAIL` for runtime
  resolveip. Success cases explicitly use `SCHEDULE_RESOLVE_FAIL=0`.
- The final stop-timer case uses the existing shared DNS stub's `dns-stop-delay`
  control. Only formal DNS stop executes the real **0.8-second** sleep; private
  bootstrap still supplies query sockets and rooted proc ownership.
- `python3 tests/bootstrap-startup/schedule-compat.py` is only an exec alias of
  the formal entry. It does not rewrite sources or add a second set of oracles.

T15.8's targeted controls and restoration can be reproduced with:

```sh
python3 tests/schedule/verify-fixtures.py
```

This verifies exact source equality to baseline `6c3a0ca` outside the two fixture
adaptations, runs the formal entry, runs each negative control in an independent
disposable tracked-source copy, then runs the restored compatibility alias.
Host binaries are reused read-only. No production file or shared stub is changed.
A read-only observer records the formal DNS handler's actual `sleep 0.8` child;
its sampled lifetime is diagnostic, not a replacement timing/business oracle.
The helper does not run from shared review or B3's default runner.

`evidence/t15.8-baseline*.log` preserves the original 35/5 run and its five
setup diagnostics. `t15.8-fixed.log`, the two negative-control logs,
`t15.8-restored-compat.log`, and `t15.8-fixture-observations.log` record this card's
results. Repeating the helper updates only the latter five logs, not the baseline.
