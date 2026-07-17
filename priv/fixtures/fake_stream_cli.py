#!/usr/bin/env python3
import json
import sys


def emit(value):
    print(json.dumps(value), flush=True)


args = sys.argv[1:]

if "exec" in args and "--json" in args:
    emit({"type": "thread.started", "thread_id": "codex-fixture-session"})
    emit(
        {
            "type": "item.completed",
            "thread_id": "codex-fixture-session",
            "item": {"type": "agent_message", "text": "codex-ok"},
        }
    )
    emit(
        {
            "type": "turn.completed",
            "thread_id": "codex-fixture-session",
            "status": "completed",
            "usage": {"input_tokens": 2, "output_tokens": 1},
        }
    )
elif "--prompt" in args:
    emit({"type": "init", "session_id": "gemini-fixture-session", "model": "fixture"})
    emit({"type": "message", "role": "assistant", "content": "gemini-ok", "delta": True})
    emit(
        {
            "type": "result",
            "status": "success",
            "stats": {"input_tokens": 2, "output_tokens": 1},
        }
    )
elif "--print" in args:
    emit(
        {
            "type": "system",
            "subtype": "init",
            "session_id": "claude-fixture-session",
            "model": "fixture",
            "tools": [],
        }
    )
    emit(
        {
            "type": "stream_event",
            "session_id": "claude-fixture-session",
            "event": {
                "type": "content_block_delta",
                "delta": {"type": "text_delta", "text": "claude-ok"},
            },
        }
    )
    emit(
        {
            "type": "result",
            "subtype": "success",
            "session_id": "claude-fixture-session",
            "result": "claude-ok",
            "usage": {"input_tokens": 2, "output_tokens": 1},
        }
    )
elif "--execute" in args:
    emit(
        {
            "type": "system",
            "subtype": "init",
            "session_id": "amp-fixture-session",
            "tools": [],
        }
    )
    emit(
        {
            "type": "assistant",
            "session_id": "amp-fixture-session",
            "message": {"content": [{"type": "text", "text": "amp-ok"}]},
        }
    )
    emit(
        {
            "type": "result",
            "subtype": "success",
            "session_id": "amp-fixture-session",
            "result": "amp-ok",
            "usage": {"input_tokens": 2, "output_tokens": 1},
        }
    )
else:
    print("unsupported fixture invocation", file=sys.stderr)
    sys.exit(2)
