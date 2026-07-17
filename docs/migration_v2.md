# Migrating to Jido.Harness 2.0

Jido.Harness 2.0 consolidates the former provider harness packages into one
normalization and lifecycle runtime. It supports Amp, Claude Code, Codex, Gemini
CLI, Grok, Kimi Code, OpenCode, Pi, and Z.AI through direct CLI adapters.

This is a clean breaking API.

## Removed boundaries

- provider namespaces such as `Jido.Amp` and provider SDK facades;
- adapter auto-discovery and compatibility shims;
- the legacy Exec facade and preflight shell templates;
- workspace provisioning and Sprite integration;
- Jido Actions, Signals, and observation wrappers;
- dependencies on `jido`, `jido_shell`, Sprites, Splode, provider SDKs, and
  generic subprocess wrappers.

`cwd` now means an existing local directory and is validated before execution.

## Choose the new lifecycle API

| Previous intent | v2 API |
| --- | --- |
| Make one blocking provider call | `Jido.Harness.run/3` |
| Start and control finite work | `Jido.Harness.Run` |
| Maintain multi-turn context | `Jido.Harness.Session` |
| Supervise a direct executable | `Jido.Harness.Process` |

```elixir
{:ok, run_id} =
  Jido.Harness.Run.start(:amp, %{
    prompt: prompt,
    cwd: cwd
  })

{:ok, %Jido.Harness.RunResult{} = result} =
  Jido.Harness.Run.await(run_id)
```

For blocking use:

```elixir
{:ok, %Jido.Harness.RunResult{} = result} =
  Jido.Harness.run(:gemini, prompt, cwd: cwd)
```

## Replace provider response types

Provider SDK responses and events become:

- `Jido.Harness.RunResult` for a terminal finite response;
- `Jido.Harness.TurnResult` for a terminal session turn;
- `Jido.Harness.Event` for ordered provider activity;
- `Jido.Harness.Error` for normalized API failures;
- `Jido.Harness.ProviderStatus` and capability structs for discovery.

Code that needs unmapped provider data can handle `:provider_event` explicitly.
See [Normalization and the data model](../guides/normalization_and_data_model.md).

## Replace identifiers

| ID | Meaning |
| --- | --- |
| `run_id` | one finite harness execution |
| `process_id` | one managed OS process |
| `session_id` | one interactive harness resource |
| `turn_id` | one accepted turn inside a session |
| `provider_session_id` | provider-owned resume identifier |

Do not use a provider session ID to look up, cancel, or prune a harness
resource. There is no compatibility alias for the former provider `session_id`
request field.

## Replace interactive conversations

```elixir
{:ok, session_id} = Jido.Harness.Session.start(:codex, %{cwd: cwd})
{:ok, turn_id} = Jido.Harness.Session.send_message(session_id, prompt)
{:ok, turn} = Jido.Harness.Session.await(session_id, turn_id)
{:ok, next_id} = Jido.Harness.Session.follow_up(session_id, follow_up)
:ok = Jido.Harness.Session.close(session_id)
```

Session streams and replay use cursors like finite runs. Unsupported steering,
approval, attachment, or configuration behavior now fails according to the
selected transport's declared capabilities.

## Replace errors and events

Replace Splode matching with `%Jido.Harness.Error{}` and provider event structs
with `%Jido.Harness.Event{}`. Every terminal run, turn, and session receives one
terminal event for its scope.

Result text is bounded. When `text_truncated?` is true, replay the ordered event
journal for the complete retained sequence.

## Replace shell and workspace code

Delete harness-specific `jido_shell` and Sprite workspace setup. Supply an
existing `cwd`. For direct executable ownership, use a structured
`Jido.Harness.ProcessSpec` with executable plus argv.

`jido_shell` remains a separate package and is not part of v2 execution.
