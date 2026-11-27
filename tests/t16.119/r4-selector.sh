#!/bin/sh
# Exercise the released selector, not a copy of its logic. Requires the r4 tag.
set -eu
cd "$(dirname "$0")/../.."
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
git show v1.3.1-r4:aether-proxy/src/lib/update.uc > "$t/r4.uc"
printf '\nexport { package_asset };\n' >> "$t/r4.uc"
tests/host/ucode -L "$t/*.uc" -e '
import { package_asset } from "r4";
let name = "aether-proxy", formats = ["ipk", "apk"], arches = ["aarch64_generic", "x86_64"];
let cur = {}, old = { all: {} };
for (let f in formats) {
  for (let a in arches) {
    cur[a] ??= {};
    cur[a][f] = { url: a + "." + f, size: 1, sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
  }
  old.all[f] = { url: "historical." + f, size: 1, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" };
}
let m = { packages: { [name]: { current: { version: "new", assets: cur }, previous: { version: "r4", assets: old } } } };
for (let f in formats) for (let a in arches) {
  let pm = f == "ipk" ? "opkg" : "apk";
  assert(package_asset(m, name, a, pm, false).url == a + "." + f);
  assert(package_asset(m, name, a, pm, true).url == "historical." + f);
  assert(package_asset(m, name, "unsupported", pm, false) == null);
}
print("PASS r4 current arch / previous all, ipk and apk\n");'
