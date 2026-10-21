#!/usr/bin/env python3
"""Validate the latest committed reload event against docs/04's public contract."""
import json
import os
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
steps = args["steps"]
parents = {"config_render", "resolve_node", "validate", "sets_export_render", "actions"}
assert set(steps) == parents | {"detail"}, args
assert all(type(steps[key]) is int and steps[key] >= 0 for key in parents), args
# Rounded substeps can exceed a rounded total by at most one ms per boundary.
total = sum(steps[key] for key in parents)
assert args["elapsed_ms"] + len(parents) >= total, args
if len(sys.argv) > 5:
    # A test-only sleep in the daemon's live-current hashing precedes reload.run().
    assert args["elapsed_ms"] - total >= int(sys.argv[5]), args

# Every actual operation has a detail, and skipped operations must not get fake zeros.
detail = steps["detail"]
groups = {
    "config_render": {"read", "render", "stage"},
    "validate": {"precheck", "nft_check"},
    "sets_export_render": set(),
    "actions": set(args["actions"]),
}
if "restart_xray" in args["actions"]:
    groups["validate"].add("xray_test")
if "nft_replace" in args["actions"]:
    groups["sets_export_render"].add("nft_render")
    # No live table means nothing was exported, so no sets_export key either.
    if os.environ.get("EXPECT_NO_EXPORT") != "1":
        groups["sets_export_render"].add("sets_export")
assert type(detail) is dict, args
assert set(detail) == set().union(*groups.values()), args
assert all(type(ms) is int and ms >= 0 for ms in detail.values()), args
for parent, children in groups.items():
    assert sum(detail[key] for key in children) <= steps[parent], (parent, args)
# Both nft passes accumulate into nft_check (the stub can make each one take 0.3 s).
if os.environ.get("NFT_CHECK_MIN"):
    assert detail["nft_check"] >= int(os.environ["NFT_CHECK_MIN"]), args
print(json.dumps(args, ensure_ascii=False, sort_keys=True))
