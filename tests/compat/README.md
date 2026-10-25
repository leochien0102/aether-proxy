# Previous-release update compatibility (T9.39)

Run after `bash tests/host/bootstrap.sh`:

```sh
bash tests/compat/run.sh
```

The frozen 0.3.0-r1 page, update model, common job helper, rpcd plugin and ACL
are unmodified files from `v0.3.0-r1`. The directory preserves paths relative
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

The contract wording in docs/08 mentions `ok` and a `job` object. Existing
successful `status`/`job start` omit `ok`; `job status` returns the flat job record.
The frozen old client accepts these shapes. The test preserves these real wire
shapes rather than inventing an envelope or changing production code; see the
`TODO(design)` beside `assert_inventory` and the task report.
