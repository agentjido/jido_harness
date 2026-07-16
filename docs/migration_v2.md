# Migrating to Jido.Harness 2.0

Jido.Harness 2.0 consolidates the former Amp, Claude, Codex, Gemini, and
OpenCode harness packages and adds Grok, Z.AI, and Kimi Code. Z.AI uses its
officially supported Claude Code integration under the distinct `:zai`
provider. Kimi Code uses its official headless JSONL interface under `:kimi`.
It is a clean breaking API.

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
- `session_id` is the provider's resumable session or thread identifier.

Do not use a provider session ID to look up or cancel a harness run.

## Errors and events

Replace Splode error matching with `%Jido.Harness.Error{}`. Replace provider
event structs with `%Jido.Harness.Event{}` and handle `:provider_event` for data
without a canonical mapping.

Exactly one terminal event is present in every completed result.

## Shell and workspace code

Delete harness-specific `jido_shell` and Sprite workspace setup. If an adapter
needs a direct CLI process, use the v2 structured process manager. `jido_shell`
remains an unrelated package and is not part of this migration.
