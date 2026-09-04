#!/usr/bin/env python3
"""Finite OpenCode JSON fixture. No provider or network access is used."""
import json
import os
import sys

args = sys.argv[1:]
assert args[0] == "run"
assert args[args.index("--format") + 1] == "json"
with open(os.environ["HARNESS_FIXTURE_ARGV"], "w", encoding="utf-8") as output:
    json.dump(args, output)
session_id = args[args.index("--session") + 1] if "--session" in args else "ses_fixture"
for event_type in ("step_start", "step_finish"):
    print(json.dumps({
        "type": event_type,
        "timestamp": 1788170000000,
        "sessionID": session_id,
        "part": {"type": event_type.replace("_", "-")},
    }), flush=True)
