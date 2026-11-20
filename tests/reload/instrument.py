#!/usr/bin/env python3
"""Count real reads/renderers in an isolated module copy, never in product code.

The daemon suite still uses the unmodified modules. Entry traces expose duplicate
loads or renders, and stderr mirrors errors that normally only go to syslog.
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

path = target / "log.uc"
text = path.read_text()
anchor = "\tappend_event(level, code, args);"
if text.count(anchor) != 1:
    raise RuntimeError("instrumentation anchor is not unique: log.uc event append")
path.write_text(text.replace(anchor, anchor + "\n\tif (level == 'error')"
                            "\n\t\twarn('TRACE reload error: ' + format_line(code, args, message) + '\\n');"))
