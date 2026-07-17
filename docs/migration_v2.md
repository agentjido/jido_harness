# Migrating to Jido.Harness 2.0

Jido.Harness 2.0 consolidates the former Amp, Claude, Codex, Gemini, and
OpenCode harness packages and adds Grok, Z.AI, Kimi Code, and Pi. Z.AI uses its
officially supported Claude Code integration under the distinct `:zai`
provider. Kimi Code and Pi use their official headless JSONL interfaces under
`:kimi` and `:pi`. It is a clean breaking API.

## Removed

- legacy provider namespaces such as `Jido.Amp`;
- compatibility shims and adapter auto-discovery;
- the legacy Exec facade, preflight shell templates, and workspace provisioning;
- Sprite integration;
- Jido Actions, Signals, and observation wrappers;
- dependencies on `jido`, `jido_shell`, Sprites, and Splode.

`cwd` now means an existing local directory and is validated before a run.

## Replace provider-package calls

Use a built-in provider atom:

```elixir
{:ok, run_id} = Jido.Harness.start(:amp, %{prompt: prompt, cwd: cwd})
{:ok, result} = Jido.Harness.await(run_id)
```

For a blocking call:

```elixir
{:ok, result} = Jido.Harness.run_sync(:gemini, prompt, cwd: cwd)
```

`run/3` now returns `{:ok, run_id, event_enumerable}`. It no longer returns a
provider package's stream directly.

## IDs

- `run_id` identifies one harness-owned execution.
- `process_id` identifies one directly managed OS process.
- `session_id` identifies one harness-owned interactive session.
- `provider_session_id` is a provider's resumable session or thread identifier.
- `turn_id` identifies one turn inside a harness session.

Do not use a provider session ID to look up or cancel a harness run or session.
There is intentionally no compatibility alias for the former provider
`session_id` request field.

## Interactive conversations

Use `open_session/3` for multi-turn work, `send_message/3` for an idle session,
and `follow_up/3` for FIFO queuing. Session streams and replay are cursor-based,
just like finite runs. `interrupt_turn/2` ends the active turn but preserves a
healthy session; `close_session/1` resolves approvals as denied, stops the
transport, and emits one terminal session event.

## Errors and events

Replace Splode error matching with `%Jido.Harness.Error{}`. Replace provider
event structs with `%Jido.Harness.Event{}` and handle `:provider_event` for data
without a canonical mapping.

Exactly one terminal event is present in every completed result.

`RunResult` and `TurnResult` retain at most the configured in-memory text tail.
When output exceeds that bound, `text_truncated?` is true and `text` contains
the newest retained text; cursor replay remains the source for the complete
journaled event sequence.

## Shell and workspace code

Delete harness-specific `jido_shell` and Sprite workspace setup. If an adapter
needs a direct CLI process, use the v2 structured process manager. `jido_shell`
remains an unrelated package and is not part of this migration.
