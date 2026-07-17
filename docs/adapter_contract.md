# Adapter contract reference

Every finite-run provider implements `Jido.Harness.Adapter`. Public adapter
boundaries use normalized Jido.Harness types rather than provider SDK structs or
arbitrary maps.

## Required callbacks

| Callback | Contract |
| --- | --- |
| `spec/0` | returns a validated `Jido.Harness.AdapterSpec` |
| `run/2` | returns `{:ok, enumerable}` of `Jido.Harness.Event` values or `{:error, reason}` |
| `status/1` | returns normalized `Jido.Harness.ProviderStatus` readiness |

`install/2` and native `cancel/2` are optional. Direct CLI adapters normally
cancel through the harness process manager.

## Adapter specification

`AdapterSpec` declares:

- provider atom, display name, executable, documentation URL, and installation
  recipe;
- finite-run capabilities;
- supported normalized request fields;
- accepted values when normalized enum support is narrower;
- accepted nested `provider_options` keys;
- adapter-level request defaults;
- interactive transport specifications.

Declarations are enforced before execution. A non-default normalized field
that is not declared fails. A normalized value outside `normalized_values`
fails. Unknown provider options fail. Provider-specific options cannot shadow a
normalized request field.

## Run callback context

`run/2` receives a validated `Jido.Harness.RunRequest` and context:

```elixir
%{
  run_id: "run_...",
  provider: :provider,
  config: %{},
  telemetry_context: %{run_id: "run_...", provider: :provider},
  process_manager: Jido.Harness.ProcessManager,
  run_owner: owner_pid
}
```

CLI adapters must start processes through the supplied process manager and bind
them to `run_owner`. They must not start unmanaged ports, interpolate a shell
command, or retry billable work.

## Event output

The returned enumerable emits `Jido.Harness.Event` structs. Map provider records
to canonical types only when the semantics are preserved. Unknown or
loss-sensitive records use `:provider_event` and may retain their original
value in `raw`.

The run worker attaches stable run identity and monotonic sequence values. Raw
provider values remain in memory and are not persisted. Structured sensitive
fields, bearer credentials, and configured credential environment values are
redacted from journal records.

## Terminal behavior

The run manager guarantees exactly one of:

- `:run_completed`
- `:run_failed`
- `:run_cancelled`

If an adapter enumerable ends without a terminal event, the run manager adds a
terminal event. Events after the first terminal event are ignored.

Adapters must not fabricate success merely because their process exited with
status zero; they must map the provider protocol's terminal semantics where
available.

## Status behavior

`status/1` must not send an agent prompt. It should report:

- executable installation;
- version and compatibility;
- authentication evidence or `:unknown`;
- readiness to attempt a smoke run;
- finite-run capabilities.

Installation guidance belongs in the adapter spec. `install/2` must remain an
explicit caller action and support preview behavior where the adapter exposes
an installation recipe.

## Interactive transports

Interactive providers declare one or more `SessionTransportSpec` entries. Each
entry selects a `Jido.Harness.SessionAdapter` implementing:

- `open/2`
- `send/3`
- `interrupt/2`
- `close/1`

Steering, approval responses, and dynamic configuration are optional callbacks.

Each transport declares session fields, session provider options, turn fields,
turn provider options, configuration fields, and
`Jido.Harness.InteractionCapabilities`. Capability values distinguish
`:native`, `:managed`, `:process`, and unsupported behavior.

The transport declaration is the source of truth. A public session function may
exist even when a particular provider transport rejects that capability.

## Built-in transport matrix

| Provider | Transport | Execution model |
| --- | --- | --- |
| Amp | `:stream_json_resume` | resumed stream-JSON process per turn |
| Claude | `:stream_json_resume` | resumed stream-JSON process per turn |
| Codex | `:exec_jsonl_resume` | resumed exec-JSONL process per turn |
| Gemini | `:stream_json_resume` | resumed stream-JSON process per turn |
| Grok | `:streaming_json_resume` | resumed streaming-JSON process per turn |
| Kimi | `:acp` | persistent ACP JSON-RPC process |
| OpenCode | `:acp` | persistent ACP JSON-RPC process |
| Pi | `:rpc` | persistent JSONL-RPC process |
| Z.AI | `:stream_json_resume` | Claude stream JSON with Z.AI environment mapping |

Per-turn transports apply runtime and idle timeouts to the active process.
Persistent protocol processes may remain idle indefinitely while waiting for
session input, subject to the configured session idle timeout.

## Verification

An adapter change should pass deterministic mapper and fake-CLI tests, lifecycle
and cleanup contracts, affected live integration profiles, documentation
compilation, static analysis, and package build verification.
