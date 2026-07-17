#!/usr/bin/env python3
import json
import sys

session_id = "pi-fixture-session"
turn_number = 0
pending = False


def send(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def complete(text, aborted=False):
    global turn_number
    if aborted:
        send(
            {
                "type": "agent_end",
                "willRetry": False,
                "messages": [
                    {
                        "role": "assistant",
                        "stopReason": "aborted",
                        "errorMessage": "fixture abort",
                    }
                ],
            }
        )
    else:
        turn_number += 1
        send({"type": "turn_start"})
        send(
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_delta", "delta": text},
            }
        )
        send(
            {
                "type": "message_end",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": text}],
                    "usage": {"input": 1, "output": 1},
                },
            }
        )
    send({"type": "turn_end"})


send({"type": "session", "id": session_id})

for line in sys.stdin:
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue

    kind = message.get("type")

    if kind == "prompt":
        if message.get("message") == "hold":
            pending = True
        else:
            complete("fixture-" + str(turn_number + 1))
    elif kind == "steer" and pending:
        pending = False
        complete("steered")
    elif kind == "abort" and pending:
        pending = False
        complete("", aborted=True)
    elif kind in ("set_model", "set_thinking_level"):
        send({"type": "response", "command": kind, "success": True})
