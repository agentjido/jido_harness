# Adapter contract

Every v2 adapter implements `Jido.Harness.Adapter` and returns only normalized
Jido.Harness types at its public boundary.

## Required callbacks

- `spec/0` returns `%Jido.Harness.AdapterSpec{}`.
- `run/2` returns `{:ok, enumerable}` or `{:error, reason}`.
- `status/1` returns installation, compatibility, authentication, resume,
  cancellation, and readiness information.

`install/2` and native `cancel/2` are optional. Adapters without native
cancellation are cancelled by terminating their supervised run worker and
closing the underlying SDK stream.

Interactive providers also declare one or more `SessionTransportSpec` entries.
Each transport points to a `Jido.Harness.SessionAdapter` implementing `open/2`,
`send/3`, `interrupt/2`, and `close/1`; steering, approval responses, and
dynamic configuration are optional callbacks. Capability values are
`:native`, `:managed`, `:process`, or `false`, so emulation is not presented as
native protocol support. Each transport separately declares the normalized
session fields, session provider options, turn fields, turn provider options,
and dynamic configuration fields it consumes. Use `:adapter` only when the
transport faithfully supports the finite adapter's entire declaration.
The transport entry is the sole source of its adapter module; `AdapterSpec`
does not carry a second session-adapter fallback.

## Adapter specification

The spec declares:

- the provider atom and display name;
- the expected executable and explicit installation recipe;
- normalized capabilities;
- normalized request fields the provider can represent;
- any provider-specific constraints on normalized enum values;
- accepted nested `provider_options` keys;
- adapter request defaults.

Declarations are enforced. A non-default normalized value that is not listed in
`normalized_options` fails before the adapter is invoked. Unknown
`provider_options` keys fail before execution.

The same rule applies at the transport boundary: a session or turn option that
the selected transport would ignore is rejected before the transport opens or
the turn is dispatched.

## Run callback

`run/2` receives a validated `%Jido.Harness.RunRequest{}` and this context:

```elixir
%{
  run_id: "run_...",
  provider: :codex,
  config: %{},
  telemetry_context: %{run_id: "run_...", provider: :codex},
  process_manager: Jido.Harness.ProcessManager,
  run_owner: #PID<...>
}
```

The returned enumerable emits `%Jido.Harness.Event{}` values. Provider events
that cannot be mapped losslessly use `:provider_event` and retain the raw value
in memory. Raw provider values are not persisted to disk. Structured sensitive
fields, bearer credentials, and configured credential environment values are
redacted from journal records.

Adapters must not emit arbitrary maps, retry a billable run, start an unmanaged
CLI process, or create shell command strings. Direct CLI adapters use the
harness process manager. SDK-backed adapters retain their SDK backend.

## Terminal events

The run manager guarantees exactly one of:

- `:run_completed`
- `:run_failed`
- `:run_cancelled`

If an adapter finishes without a terminal event, the manager adds one. Events
after a terminal event are ignored.

Session workers separately guarantee exactly one of `:session_closed`,
`:session_failed`, or `:session_cancelled`. Each accepted turn gets exactly one
of `:turn_completed`, `:turn_failed`, or `:turn_interrupted`.

## Interactive transport matrix

| Provider | Default transport | Execution model |
| --- | --- | --- |
| Amp | `:sdk` | persistent SDK streaming-input process |
| Claude | `:sdk` | persistent Claude control client |
| Codex | `:exec_jsonl_resume` | resumed JSONL process per turn |
| Codex opt-in | `:app_server` | experimental persistent app-server |
| Gemini | `:sdk` | persistent SDK session |
| Grok | `:streaming_json_resume` | resumed streaming-JSON process per turn |
| Kimi | `:acp` | persistent ACP JSON-RPC process |
| OpenCode | `:acp` | persistent ACP JSON-RPC process |
| Pi | `:rpc` | persistent JSONL-RPC process |
| Z.AI | `:claude_sdk` | Claude control client with Z.AI environment mapping |

Persistent protocol processes wait indefinitely for input. Runtime and idle
timeouts apply to active turns, not to an idle protocol process.

## Provider-specific options

Provider-specific escape hatches belong under `provider_options`. They cannot
use the name of a normalized field. Adapters must validate their values before
launch and must not silently ignore an advertised key.
