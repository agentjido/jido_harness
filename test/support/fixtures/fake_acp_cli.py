#!/usr/bin/env python3
import json
import os
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
            "providerEnvelope": {"trace": "fixture-envelope", "secret": "raw-only-secret"},
            "fixturePromptId": request_id,
            "params": {
                "sessionId": session_id,
                "providerParameter": "fixture-parameter",
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text},
                    "providerExtension": {"trace": "fixture-trace"},
                },
            },
        },
        fragmented=True,
    )
    send(
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": session_id,
                "update": {
                    "sessionUpdate": "usage_update",
                    "used": 3,
                    "size": 10,
                },
            },
        }
    )
    send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": stop_reason}})


def request_permission():
    send(
        {
            "jsonrpc": "2.0",
            "id": 99,
            "method": "session/request_permission",
            "providerEnvelope": {"trace": "permission-envelope"},
            "params": {
                "sessionId": session_id,
                "providerParameter": "permission-parameter",
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
                        "sessionCapabilities": {"close": {}},
                        "promptCapabilities": {"image": True, "embeddedContext": True},
                    },
                    "agentInfo": {"name": "fixture-acp", "version": "1.0.0"},
                },
            }
        )
    elif method == "session/new":
        result = {"sessionId": session_id}
        if os.environ.get("HARNESS_FIXTURE_MODEL_STATE") == "1":
            result["configOptions"] = [{
                "id": "model", "name": "Model", "category": "model", "type": "select",
                "currentValue": "fixture-effective-model",
                "options": [{"value": "fixture-effective-model", "name": "Fixture model"}],
            }]
        send({"jsonrpc": "2.0", "id": request_id, "result": result})
    elif method == "session/load":
        session_id = message.get("params", {}).get("sessionId", session_id)
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id}})
    elif method == "session/prompt":
        text = " ".join(
            block.get("text", "")
            for block in message.get("params", {}).get("prompt", [])
            if isinstance(block, dict)
        )
        if text in ["fail", "raise", "terminal-fail"]:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32000, "message": "fixture terminal failure"},
                }
            )
        elif text == "large":
            complete_prompt(request_id, text="0123456789" * 1000)
        elif "approval" in text:
            pending_prompt = request_id
            request_permission()
            if "duplicate" in text:
                request_permission()
        elif "wait" in text:
            pending_prompt = request_id
        elif "invalid" in text:
            sys.stdout.write("{invalid-json}\n")
            sys.stdout.flush()
            complete_prompt(request_id)
        elif "slow" in text:
            time.sleep(0.15)
            complete_prompt(request_id)
        elif "harness-live-soak-" in text:
            complete_prompt(request_id, text=text.split()[-1])
        else:
            complete_prompt(request_id)
    elif method in ["session/set_model", "session/set_config_option", "session/set_mode"]:
        if os.environ.get("HARNESS_FIXTURE_MODEL_STATE") == "1":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": session_id,
                "update": {"sessionUpdate": "config_option_update", "configOptions": [{
                    "id": "model", "name": "Model", "category": "model", "type": "select",
                    "currentValue": "fixture-effective-model",
                    "options": [{"value": "fixture-effective-model", "name": "Fixture model"}],
                }]},
            }})
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    elif method == "session/cancel" and pending_prompt is not None:
        complete_prompt(pending_prompt, text="", stop_reason="cancelled")
        pending_prompt = None
    elif method == "session/close":
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    elif request_id == 99 and pending_prompt is not None:
        outcome = message.get("result", {}).get("outcome", {})
        selected = outcome.get("optionId", "")
        complete_prompt(pending_prompt, text="approved" if selected == "allow-once" else "denied")
        pending_prompt = None
