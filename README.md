# Jido.Harness

[![CI](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/agentjido/jido_harness.svg)](https://github.com/agentjido/jido_harness/blob/main/LICENSE)

Jido.Harness runs coding-agent CLIs from Elixir. It manages their processes and
returns common request, event, result, and error types. Runs and sessions use
Agent Client Protocol (ACP) through ExMCP.

Use it to run one task, keep a conversation open, or start work and collect its
result later. Work belongs to the application supervision tree and can
continue after the caller exits. Output retention is bounded. Runs and sessions
do not survive a BEAM or host restart.

> This checkout is the `3.0.0-rc.1` release candidate. Test it with a Git
> dependency. Review the [version 3 migration guide](guides/migrations/migration_v3.md)
> and [dependency audit exceptions](guides/reference/dependency_audit.md) before release use.

## Install

Add the dependency to your application's `mix.exs`:

```elixir
def deps do
  [
    {:jido_harness, github: "agentjido/jido_harness", branch: "main"}
  ]
end
```

Run `mix deps.get` and commit `mix.lock` to record the selected revision.
Use `ref:` with a full commit ID when you need a fixed source revision.

Each provider needs an installed CLI, authentication, and an ACP entry point.
Some CLIs include ACP. Others need a separate adapter. Preview the installation
from an Elixir shell started with `iex -S mix`:

```elixir
Jido.Harness.install(:codex, dry_run: true)
```

Check provider readiness without sending a prompt:

```console
mix jido_harness.check --providers codex --strict
```

Follow [Getting started](guides/getting_started.md) for installation,
authentication, and application configuration.

## Run one task

```elixir
{:ok, %Jido.Harness.RunResult{status: :completed} = result} =
  Jido.Harness.run(:codex, "Reply with exactly: harness-ready",
    cwd: File.cwd!(),
    await_timeout: 300_000
  )

IO.puts(result.text)
```

This request uses a real provider and can consume API or subscription usage.
Check `result.status` when handling results: `{:ok, result}` can also contain a
failed or cancelled task. An await timeout stops the caller's wait; it does not
cancel the task.

## Choose an API

| Need | API | Guide |
| --- | --- | --- |
| Wait for one task | `Jido.Harness.run/3` | [One-shot requests](guides/one_shot_requests.md) |
| Start work and return later | `Jido.Harness.Run` | [Detached runs](guides/detached_runs.md) |
| Keep a multi-turn conversation | `Jido.Harness.Session` | [Interactive sessions](guides/interactive_sessions.md) |
| Manage a local executable | `Jido.Harness.Process` | [Managed processes](guides/managed_processes.md) |

Resources have stable Harness IDs. You can inspect their state, stream or
replay events, wait for completion, cancel active work, and prune retained
results. See [Choosing a workflow](guides/choosing_a_workflow.md).

## Providers

Built-in adapters cover Amp, Claude Code, Codex, Cursor CLI, Gemini CLI, Grok,
Kimi Code, OpenCode, Pi, and Z.AI. Options and capabilities differ between
providers. Unsupported options return an error.

The [provider guide](guides/providers.md) lists entry points, installation
requirements, model selection, and current isolation limits. No built-in
version 3 ACP profile advertises structured output.

## Place in the Jido ecosystem

Harness owns coding-agent execution, process lifetime, and common results.
ExMCP owns the ACP protocol. Jido Connect owns service API integrations.
Application code owns provider selection, workspace setup, approval policy,
and decisions about the result.

Harness does not require `jido` or `jido_connect`. It can run in an Elixir
application on its own. See the [dependency and scope policy](guides/reference/dependency_policy.md).

## Documentation

All guides, reference pages, design decisions, and notebooks are under `guides/`.
Generated API documentation is written to the ignored `doc/` directory.

- [Overview](guides/overview.md): resource model and runtime guarantees.
- [Getting started](guides/getting_started.md): one provider and one request.
- [Operations](guides/operations.md): limits, telemetry, retention, and shutdown.
- [Configuration reference](guides/reference/configuration_reference.md): application settings.
- [Escript packaging](guides/escripts.md): package the native process helper.
- [Testing](guides/testing.md): local fixtures and optional live contracts.

Runnable Livebooks are under `guides/livebooks/`:

- [One-shot requests](guides/livebooks/01_one_shot_requests.livemd).
- [Detached runs, streams, and replay](guides/livebooks/02_detached_runs.livemd).
- [Interactive sessions and managed processes](guides/livebooks/03_sessions_and_processes.livemd).

Provider cells use live CLIs. The managed-process example runs locally.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, the file map, checks, and
release preparation. Local dependency workarounds require a source checkout;
see [Local workarounds](guides/local_workarounds.md).
