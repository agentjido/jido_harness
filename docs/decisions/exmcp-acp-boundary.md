# ExMCP ACP boundary

GitHub issue `agentjido/jido_harness#61` owns this migration.

## Decision

Harness uses stable ExMCP 1.x for ACP messages, protocol validation, and
protocol request correlation. Harness keeps all stateful coding-agent lifecycle
behavior.

The Harness-owned ExMCP transport starts the provider executable through
`Jido.Harness.ProcessManager`. It gives complete ACP frames to ExMCP and writes
ExMCP frames to the managed process. It does not decode ACP JSON or correlate
JSON-RPC request IDs.

The Harness-owned ExMCP client handler converts session updates into Harness
events. It converts permission callbacks into asynchronous Harness approval
requests. Harness creates the approval ID and applies its approval timer. The
handler waits for the Harness decision and returns the selected ACP permission
outcome to ExMCP.

## Function map

| ACP operation | ExMCP function | Harness responsibility |
| --- | --- | --- |
| initialize | `ExMCP.ACP.Client.start_link/1` | executable, argv, environment policy, process owner |
| session/new | `ExMCP.ACP.Client.new_session/3` | Harness session ID and retained lifecycle state |
| session/load | `ExMCP.ACP.Client.load_session/4` | separate provider session ID |
| session/prompt | `ExMCP.ACP.Client.prompt/4` | Harness turn ID, timers, events, result, and replay |
| session/cancel | `ExMCP.ACP.Client.cancel/2` | process and turn lifecycle |
| session/request_permission | `ExMCP.ACP.Client.Handler` callback | approval ID, timeout, stale response, and default denial |
| session/close | `ExMCP.ACP.Client.end_session/2` | session close state and process cleanup |

Harness also keeps event sequence numbers, journals, retention, process groups,
signal escalation, output streaming, and cleanup. No Harness lifecycle type is
an ExMCP type.

## Compatibility result

The compatibility spike found no gap that prevents this adapter.

ExMCP requires finite internal request deadlines. Harness sets each ExMCP
deadline after the related Harness deadline so the Harness timer decides the
normal result. A Harness `:infinity` timeout uses the maximum supported internal
timer, about 49 days. This is the only recorded timeout limit in the adapter.

ExMCP now handles two invalid wire cases before Harness lifecycle code:

- A malformed ACP frame is ignored by ExMCP and does not create a Harness
  `decode_error` provider event.
- A duplicate outstanding JSON-RPC request ID is rejected by ExMCP and does not
  create a second Harness approval request.

Harness public session, turn, event, replay, retention, approval, and process
contracts do not otherwise change. Approval request IDs remain opaque strings,
but Harness now generates them independently from the ACP JSON-RPC ID.
