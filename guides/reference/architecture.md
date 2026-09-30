# Architecture

Harness owns coding-agent lifecycle. ExMCP owns the Agent Client Protocol.
Every built-in finite run and interactive session uses this same boundary.

## Execution path

```text
RunRequest or SessionRequest
          -> provider AdapterSpec and ACPAgentSpec
          -> Harness process manager
          -> managed ACP executable
          -> ExMCP ACP client
          -> Harness events and terminal results
```

A finite run opens one temporary ACP session and sends one turn. An interactive
session keeps its ACP process open for later turns. Local processes can also
be managed directly through `Jido.Harness.Process`.

## Responsibilities

| Component | Owns |
| --- | --- |
| Provider adapter | CLI discovery, status, installation, option declarations, and provider configuration mapping |
| Harness | Resource IDs, supervisors, environment policy, process groups, timers, approvals, events, replay, and retention |
| ExMCP | ACP encoding, parsing, validation, request IDs, and response correlation |
| Host application | Workspaces, provider choice, authorization policy, retries, and durable job records |

The transport bridge splits stdout into complete frames and sends ExMCP's
encoded frames to the managed process. It enforces a frame-size limit and
handles process exit and output drain. It does not decode ACP JSON or keep a
JSON-RPC request map.

The client handler maps ACP session updates to Harness events. Permission
callbacks become asynchronous Harness approval requests. Harness creates the
approval ID, applies its timer, and returns the selected permission outcome to
ExMCP.

## ACP operations

| Operation | ExMCP API | Harness work |
| --- | --- | --- |
| Initialize | `ExMCP.ACP.Client.start_link/1` | Executable, arguments, environment, and process owner |
| Create a session | `ExMCP.ACP.Client.new_session/3` | Harness session identity and lifecycle |
| Load a session | `ExMCP.ACP.Client.load_session/4` | Provider resume ID |
| Send a prompt | `ExMCP.ACP.Client.prompt/4` | Run or turn ID, timers, events, result, and replay |
| Cancel | `ExMCP.ACP.Client.cancel/2` | Turn and process lifetime |
| Request permission | `ExMCP.ACP.Client.Handler` callbacks | Approval ID, deadline, stale response handling, and default denial |
| End a session | `ExMCP.ACP.Client.end_session/2` | Terminal state and process cleanup |

## Raw messages and protocol errors

ExMCP message-context callbacks supply the decoded ACP message for
`Event.raw`. A separate ACP adapter can translate or omit native provider
fields before that message reaches Harness. Raw messages stay in memory and
are excluded from disk journals. See the
[event reference](event_reference.md#provider-events-and-replay-gaps).

Malformed ACP frames are handled by ExMCP and do not create a Harness
`decode_error` event. Duplicate outstanding JSON-RPC request IDs are rejected
before another Harness approval request is created.

## Internal deadlines

ACP initialization has a 30-second startup limit. Resource execution limits
and caller await limits remain separate.

ExMCP internal request and handler deadlines use the related Harness timeout
plus a five-second margin, capped at `4_294_967_295` milliseconds. A Harness
`:infinity` value maps to that internal maximum, about 49 days. This limit
does not establish durable execution across application restarts.

Harness consumes ExMCP from Hex. See [Dependencies](dependencies.md) for
current requirements and audit exceptions.
