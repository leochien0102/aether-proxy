#!/usr/bin/env python3
"""Extract only dated releases and the two user-facing sections; no git or network."""
import datetime
import json
from pathlib import Path
import re
import sys

VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-r([1-9]\d*)")
LIMIT = 8
MARKER = "/* @RELEASES@ */ []"


def releases(directory):
    result = []
    for path in Path(directory).glob("*.md"):
        match = VERSION.fullmatch(path.stem)
        if not match:
            continue
        text = path.read_text(encoding="utf-8")
        header = text.split("\n## ", 1)[0]
        date = re.search(r"^发布日期[：:]\s*(\d{4}-\d{2}-\d{2})\s*$", header, re.M)
        if "未发布" in header or not date:
            continue
        datetime.date.fromisoformat(date[1])
        sections = {}
        title = None
        for line in text.splitlines():
            if line.startswith("## "):
                title = line[3:].strip()
                sections[title] = []
            elif title in ("主要变化", "升级须知") and line.strip():
                # Keep prose as text; only remove the list prefix and fold continuations.
                lines = sections[title]
                if line.startswith("- "):
                    lines.append(line[2:])
                elif line.startswith("  ") and lines:
                    lines[-1] += " " + line.strip()
                else:
                    lines.append(line.strip())
        result.append({"version": path.stem, "changes": sections.get("主要变化", []),
                       "notes": sections.get("升级须知", [])})
    result.sort(key=lambda r: tuple(map(int, VERSION.fullmatch(r["version"]).groups())), reverse=True)
    return result[:LIMIT]


def main():
    directory, module = map(Path, sys.argv[1:])
    # Missing source must fail the build, not silently ship an empty history.
    if not directory.is_dir():
        raise SystemExit(f"release directory missing: {directory}")
    source = module.read_text(encoding="utf-8")
    if source.count(MARKER) != 1:
        raise SystemExit("release data marker missing or duplicated")
    module.write_text(source.replace(MARKER, json.dumps(releases(directory), ensure_ascii=True)), encoding="utf-8")


if __name__ == "__main__":
    main()
