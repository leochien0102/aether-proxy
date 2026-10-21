#!/usr/bin/env python3
"""Validate the latest committed reload event against docs/04's public contract."""
import json
import sys

path, from_node, to_node, actions = sys.argv[1:5]
with open(path, encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream if line.strip()]
event = [item for item in events if item["code"] == "RELOAD_APPLIED"][-1]
assert event["level"] == "notice", event
args = event["args"]
assert set(args) == {"from_node", "to_node", "actions", "elapsed_ms", "steps"}, args
assert args["from_node"] == from_node, args
assert args["to_node"] == to_node, args
assert args["actions"] == actions.split(","), args
assert type(args["elapsed_ms"]) is int and args["elapsed_ms"] >= 0, args
assert set(args["steps"]) == {"config_render", "resolve_node", "validate", "sets_export_render", "actions"}, args
assert all(type(ms) is int and ms >= 0 for ms in args["steps"].values()), args
# Rounded substeps can exceed a rounded total by at most one ms per boundary.
assert args["elapsed_ms"] + len(args["steps"]) >= sum(args["steps"].values()), args
if len(sys.argv) > 5:
    # A test-only sleep in the daemon's live-current hashing precedes reload.run().
    assert args["elapsed_ms"] - sum(args["steps"].values()) >= int(sys.argv[5]), args
print(json.dumps(args, ensure_ascii=False, sort_keys=True))
