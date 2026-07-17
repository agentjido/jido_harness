#!/usr/bin/env python3
import json
import sys
import time

session_id = "acp-fixture-session"
pending_prompt = None


def send(value, fragmented=False):
    line = json.dumps(value, separators=(",", ":")) + "\n"
    if fragmented:
        midpoint = max(1, len(line) // 2)
        sys.stdout.write(line[:midpoint])
        sys.stdout.flush()
        time.sleep(0.01)
        sys.stdout.write(line[midpoint:])
    else:
        sys.stdout.write(line)
    sys.stdout.flush()


def complete_prompt(request_id, text="fixture-ok", stop_reason="end_turn"):
    send(
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text},
                },
            },
        },
        fragmented=True,
    )
    send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": stop_reason}})


def request_permission():
    send(
        {
            "jsonrpc": "2.0",
            "id": 99,
            "method": "session/request_permission",
            "params": {
                "sessionId": session_id,
                "toolCall": {"toolCallId": "tool-1", "title": "Fixture tool"},
                "options": [
                    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"},
                ],
            },
        }
    )


for line in sys.stdin:
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue

    method = message.get("method")
    request_id = message.get("id")

    if method == "initialize":
        send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": 1,
                    "agentCapabilities": {
                        "loadSession": True,
                        "promptCapabilities": {"image": True, "embeddedContext": True},
                    },
                    "agentInfo": {"name": "fixture-acp", "version": "1.0.0"},
                },
            }
        )
    elif method in ("session/new", "session/load"):
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id}})
    elif method == "session/prompt":
        text = " ".join(
            block.get("text", "")
            for block in message.get("params", {}).get("prompt", [])
            if isinstance(block, dict)
        )
        if "approval" in text:
            pending_prompt = request_id
            request_permission()
            if "duplicate" in text:
                request_permission()
        elif "invalid" in text:
            sys.stdout.write("{invalid-json}\n")
            sys.stdout.flush()
            complete_prompt(request_id)
        else:
            complete_prompt(request_id)
    elif method == "session/cancel" and pending_prompt is not None:
        complete_prompt(pending_prompt, text="", stop_reason="cancelled")
        pending_prompt = None
    elif request_id == 99 and pending_prompt is not None:
        outcome = message.get("result", {}).get("outcome", {})
        selected = outcome.get("optionId", "")
        complete_prompt(pending_prompt, text="approved" if selected == "allow-once" else "denied")
        pending_prompt = None
