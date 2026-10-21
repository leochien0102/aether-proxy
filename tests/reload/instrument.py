#!/usr/bin/env python3
"""Count real reads/renderers in an isolated module copy, never in product code.

The daemon suite still uses the unmodified modules. This reload suite adds entry
traces only, so duplicate loads or renders in any pipeline path are observable.
"""
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
shutil.copytree(source, target)
hooks = {
    "config.uc": [("load(cursor)", "config_load")],
    "data.uc": [("load(opts)", "data_load"), ("resolve_domain_paths(opts)", "domain_paths")],
}
for name in ("nft", "chinadns", "dnsmasq", "xray"):
    hooks[f"render/{name}.uc"] = [("render(snapshot, ctx)", f"render_{name}")]
for file, entries in hooks.items():
    path = target / file
    text = path.read_text()
    for signature, label in entries:
        anchor = f"export function {signature} {{"
        if text.count(anchor) != 1:
            raise RuntimeError(f"instrumentation anchor is not unique: {file}: {anchor}")
        text = text.replace(anchor, anchor + f"\n\twarn('TRACE T9.9 {label}\\n');")
    path.write_text(text)
