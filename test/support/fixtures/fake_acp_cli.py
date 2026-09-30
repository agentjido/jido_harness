#!/usr/bin/env python3
import json
import os
import sys
import time

if os.environ.get("HARNESS_FIXTURE_EXIT_BEFORE_INIT") == "1":
    sys.stderr.write("fixture startup failed: " + os.environ.get("HARNESS_FIXTURE_SECRET_TOKEN", "") + "\n")
    sys.stderr.flush()
    sys.exit(1)

session_id = "acp-fixture-session"
pending_prompt = None
authenticated = False
configured_mode = None


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
        time.sleep(float(os.environ.get("HARNESS_FIXTURE_INITIALIZE_DELAY", "0")))
        auth_method = os.environ.get("HARNESS_FIXTURE_REQUIRE_AUTH_METHOD")
        auth_methods = []
        if auth_method:
            auth_methods.append({"id": auth_method, "name": "Fixture Login"})

        codex_meta = {"isolation": {
            "ephemeral": os.environ.get("HARNESS_FIXTURE_ISOLATION_SUPPORT") == "1" and os.environ.get("CODEX_EPHEMERAL") == "1",
            "ignoreUserConfig": os.environ.get("HARNESS_FIXTURE_ISOLATION_SUPPORT") == "1" and os.environ.get("CODEX_IGNORE_USER_CONFIG") == "1",
        }}
        if "HARNESS_FIXTURE_CODEX_META" in os.environ:
            codex_meta = json.loads(os.environ["HARNESS_FIXTURE_CODEX_META"])

        send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": 1,
                    "agentCapabilities": {
                        "loadSession": True,
                        "_meta": {"codex": codex_meta},
                        "sessionCapabilities": {"close": {}},
                        "promptCapabilities": {"image": True, "embeddedContext": True},
                    },
                    "agentInfo": {"name": "fixture-acp", "version": "1.0.0"},
                    "authMethods": auth_methods,
                },
            }
        )
    elif method == "authenticate":
        required_method = os.environ.get("HARNESS_FIXTURE_REQUIRE_AUTH_METHOD")
        actual_method = message.get("params", {}).get("methodId")
        if required_method and actual_method != required_method:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32000, "message": "fixture authentication failed"},
                }
            )
        else:
            authenticated = True
            send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    elif method == "session/new":
        if os.environ.get("HARNESS_FIXTURE_REQUIRE_AUTH_METHOD") and not authenticated:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32000, "message": "fixture authentication required"},
                }
            )
        else:
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
        if text == "write-isolated-fixture":
            if os.environ.get("CODEX_EPHEMERAL") != "1" or os.environ.get("CODEX_IGNORE_USER_CONFIG") != "1" or configured_mode != "agent":
                sys.exit(1)
            with open("isolated-result.txt", "w") as result:
                result.write("workspace remains writable")
            complete_prompt(request_id)
            continue
        if text == "exit-with-stderr":
            sys.stderr.write("fixture command failed: " + os.environ.get("HARNESS_FIXTURE_SECRET_TOKEN", "") + "\n")
            sys.stderr.flush()
            sys.exit(1)
        if "harness-provider-panic" in text:
            sys.stderr.write("panic: could not find doneCh for checkpoint\n")
            sys.stderr.flush()
        elif text in ["fail", "raise", "terminal-fail"]:
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
        if method == "session/set_config_option" and message["params"].get("configId") == "mode":
            configured_mode = message["params"].get("value")
        if os.environ.get("HARNESS_FIXTURE_CODEX_CONFIGURATION") == "1" and method == "session/set_config_option":
            if message["params"].get("configId") not in ["model", "mode", "reasoning_effort"]:
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Unknown Codex config option"}})
                continue
        record_path = os.environ.get("HARNESS_FIXTURE_CONFIGURATION_LOG")
        if record_path:
            with open(record_path, "a") as record:
                record.write(json.dumps(message) + "\n")
        configuration_protocol = os.environ.get("HARNESS_FIXTURE_CONFIGURATION_PROTOCOL")
        if configuration_protocol == "config" and method == "session/set_model":
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "No set_model"}})
            continue
        if configuration_protocol == "legacy" and method == "session/set_config_option":
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "No config options"}})
            continue
        if configuration_protocol == "invalid" and method == "session/set_config_option":
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Invalid model"}})
            continue
        if configuration_protocol == "config" and method == "session/set_config_option" and message["params"].get("configId") != "model":
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Wrong configId"}})
            continue
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
