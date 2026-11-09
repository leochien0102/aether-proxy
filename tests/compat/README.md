# Update compatibility (T9.39 / T11.13)

## Dependency and migration contract (T11.13)

`python3 tests/compat/update-contract.py` runs offline using only the standard
library; `run.sh` runs it before the Node integration test. It reads the actual
`aether-proxy/Makefile` hard dependencies and the channel builder's
`PACKAGE_NAMES` (AST only, no import/execution). Thus future channel-managed
packages enter the closure check automatically, but system packages such as
kmod/ip-full do not. When adding a managed dependency, register it in the
publisher inventory too; do not hide channel packages as system packages.

`update-contract.json` freezes known client packages, the 0.6.3/0.6.2 support
window, explicit manual package exceptions and an ordered bridge example.
Known package snapshots were checked against v0.3.1-r1 / v0.6.2-r1 and the current
0.6.3 source; tests do not fetch tags. The migration rows in docs/08 are checked
against this fixture. Current clients require manual chinadns-ng provisioning;
0.3.1 is **manual-only**, not a direct updater to 0.6.3. Older clients are outside
the supported window. Do not add new package names to frozen known lists just
to make a newly introduced hard dependency pass: provide a real bridge or an
explicit manual migration and document the packages.

Reproduce the original missing-closure failure (intentionally exits 1):

```sh
python3 tests/compat/update-contract.py --reproduce
# 0.3.1: managed hard dependencies outside client closure: aether-xray, chinadns-ng
```

The same closure validator is used with manual exceptions removed. Negative
tests reject unregistered current/future managed dependencies, a claimed direct
0.3.1 upgrade, missing/manual table entries, and malformed bridges. Synthetic
0.6.3 → 0.6.4 → 0.6.6 → 0.6.8 assets are metadata only, not real releases. An
independent required-step list catches missing steps even if min_from is edited
to conceal the gap. Tests select only the next step, reject ordering, duplicate,
min_from, target, asset/hash errors. This pins a contract; it does **not** implement
the product bridge resolver or an update page (T11.14).

Contract v1 must not be confused with the existing wire `manifest.schema = 2`;
T11.13 does not change the wire schema to 1.

## Frozen page/RPC integration (T9.39)

T9.39 covers page/RPC shapes, **not dependency closure**. Its backend is already
new and its stub package manager does not enforce real package dependencies.
Passing it is not evidence that a complete 0.3.1 device can directly upgrade to
0.6.3. Historical 0.3.1 snapshot runs remain in Git history; the active frozen
client below is the latest formal release, not a claim that 0.3.1 remains in the
current support window.

Run after `bash tests/host/bootstrap.sh`:

```sh
bash tests/compat/run.sh
```

The frozen page, update model, common job helper, rpcd plugin and ACL are
unmodified files from the latest formal release tag (see "Snapshot history"
below). The directory preserves paths relative
to `luci-app-aether-proxy/`. CI needs no tags or historical checkout;
`frozen.sha256` guards against accidentally editing the old client. Frozen files
live under `tests/compat/fixtures/`, not `tests/fixtures/`: the latter enumerates
every child as a UCI/render fixture. This path correction was confirmed by the
design owner during T9.39; no golden runner change or placeholder UCI is needed.

The Node harness uses the existing LuCI loader/DOM/RPC doubles, but loads the
**frozen** modules. The old page's real controls call the old `common.run_job`,
whose RPC declarations reach the frozen plugin through `rpc.uc`. The plugin's
existing test executable override points to a path-only wrapper around the
**current real CLI**. Its detached workers run the real current update commands.
No production module or frozen file is patched or instrumented.

A local HTTP server serves a generated manifest and package assets, signed
with a throwaway usign key. The existing `tests/stubs/update-bin/opkg` substitute
tracks per-package versions and installation calls; real downloading, signature
verification and hash/size checks still run, as in `tests/update/run.sh`.
The backend is already at the channel version, while the old page needs an
upgrade. The fixture therefore also works with grouped forward updates (T9.38).
Everything writable lives under `tests/compat/tmp.*` and is removed on completion.

The assertions check actual old model values/messages, not just the presence of
fields. Negative controls replay modified copies of real outputs: renaming the
start job id yields `RPC_FAILED` in the old job helper; renaming check `packages`
loses the update count; renaming install `to` corrupts the old success message.

## Replacing the snapshot on each formal release

Keep **only the latest formal release** as the client tested against the next
backend. Do not edit frozen sources to make a test pass, and do not fetch old
files from tags at test runtime. When publishing version `<version>`:

1. Remove the older frozen version directory.
2. Extract the five files below from the new release tag with
   `git show v<version>:luci-app-aether-proxy/<path>`, preserving `<path>` beneath
   `tests/compat/fixtures/<version>/`:
   - `htdocs/luci-static/resources/view/aether-proxy/updates.js`
   - `htdocs/luci-static/resources/aether-proxy/model/updates.js`
   - `htdocs/luci-static/resources/aether-proxy/common.js`
   - `root/usr/share/rpcd/ucode/aetherproxy.uc`
   - `root/usr/share/rpcd/acl.d/luci-app-aether-proxy.json`
3. If job helpers have moved out of `common.js`, freeze their new file(s) too
   and load those frozen dependencies, never substitute the current client.
4. Update the version/path in `updates.test.js` and regenerate
   `tests/compat/frozen.sha256` with `sha256sum` over the extracted files.
5. Adjust fixture versions and expectations to the new released client without
   weakening assertions, then run this suite and all existing suites. Commit
   the frozen files, hashes and harness changes together.

docs/08 "更新接口（固定）" describes the wire shapes this suite pins: successful
`status`/`job start` omit `ok` (the frozen client reads `ok !== false`), and
`job status` returns the flat job record (settled in the T9.39 review).

Snapshot history: 0.3.0-r1 (T9.39); 0.3.1-r1 (grouped results); 0.6.3-r7
(latest formal client, extracted unchanged from its release tag). The r7 page
lists aether-xray directly rather than a retired xray-core row. The harness still
keeps a legacy installed xray-core record and verifies that updates never install
or alter it. The simulated 0.6.4-r1 channel is test metadata only, not a real
release, migration bridge, or promise of future compatibility.
