# Jido.Harness

[![CI](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/agentjido/jido_harness.svg)](https://github.com/agentjido/jido_harness/blob/main/LICENSE)

Jido.Harness is a supervised Elixir runtime for coding-agent CLIs. It turns
Amp, Claude Code, Codex, Gemini CLI, Grok, Kimi Code, OpenCode, Pi, and Z.AI
into caller-independent BEAM resources with one normalized API.

All agent work uses ACP through ExMCP. Native ACP CLIs and ACP adapter programs
have the same Harness execution path. Applications consume Jido.Harness structs
and do not parse provider protocols.

## What it provides

- Blocking one-shot requests through `Jido.Harness.run/3`.
- Detached supervised runs that can be listed, streamed, replayed, awaited,
  cancelled, and pruned by stable ID.
- Multi-turn ACP sessions with queued follow-ups and explicit capabilities.
- Structured local process management using executable plus argv, with stdin,
  PTY, timeouts, process-group cancellation, and retained output.
- Pull-based cursor streams and bounded replay journals for slow or reconnecting
  consumers.
- Provider readiness checks, explicit installation recipes, telemetry, and
  reusable live integration contracts.

Runs, sessions, and managed processes belong to the application supervision
tree rather than the process that starts or consumes them. They survive caller
and stream-consumer exits, but intentionally do not survive a BEAM or host
restart.

## Supported providers

| Provider | Atom | Base CLI | ACP entry point | Source |
| --- | --- | --- | --- | --- |
| Amp | `:amp` | `amp` | `amp-acp` | adapter |
| Claude Code | `:claude` | `claude` | `claude-agent-acp` | adapter |
| Codex | `:codex` | `codex` | `codex-acp` | adapter |
| Gemini CLI | `:gemini` | `gemini` | `gemini --acp` | native |
| Grok | `:grok` | `grok` | `grok agent stdio` | native |
| Kimi Code | `:kimi` | `kimi` | `kimi acp` | native |
| OpenCode | `:opencode` | `opencode` | `opencode acp` | native |
| Pi | `:pi` | `pi` | `pi-acp` | adapter |
| Z.AI | `:zai` | `claude` | `claude-agent-acp` | adapter |

Provider capabilities and normalized options differ. Jido.Harness advertises
those differences and rejects unsupported options instead of silently ignoring
them. See the [provider guide](guides/providers.md).

## Installation

Jido.Harness is not published on Hex. To test the current version 3 candidate,
install it from Git and commit the resolved revision in your lockfile:

```elixir
def deps do
  [
    {:jido_harness,
     github: "agentjido/jido_harness",
     branch: "codex/acp-only-v3"}
  ]
end
```

The first Hex release will use an explicit prerelease version. The installation
example will change to a Hex requirement only after that package exists.

The built-in adapters are registered automatically. Configure a default only
when you want providerless calls:

```elixir
config :jido_harness,
  default_provider: :codex,
  provider_config: %{
    codex: %{
      request_defaults: %{sandbox_mode: :workspace_write}
    }
  }
```

Check local CLIs without sending a prompt:

```console
mix jido_harness.check
mix jido_harness.check --providers codex,kimi --strict
```

`Jido.Harness.install/2` installs the base CLI and its ACP adapter when both
are required. Use `dry_run: true` to inspect the commands first.

For one optional live smoke request through exactly one provider:

```console
mix jido_harness.chat codex
```

The chat task may consume paid API or subscription usage.

## Escript packaging

An escript must extract the native `erlexec` helper before it starts
Jido.Harness. Configure the escript with `app: nil` and
`include_priv_for: [:erlexec]`, then call
`Jido.Harness.Escript.bootstrap_erlexec/1` from its main function. See the
[escript packaging guide](guides/escripts.md).

## First request

```elixir
{:ok, %Jido.Harness.RunResult{} = result} =
  Jido.Harness.run(:codex, "Reply with exactly: harness-ready",
    cwd: File.cwd!(),
    await_timeout: 300_000
  )

result.status
#=> :completed

result.text
#=> "harness-ready"
```

The result has the same top-level shape regardless of provider:

```elixir
%Jido.Harness.RunResult{
  run_id: "run_...",
  provider: :codex,
  provider_session_id: "...",
  status: :completed,
  text: "harness-ready",
  text_truncated?: false,
  usage: %{},
  events: [%Jido.Harness.Event{}, ...],
  metadata: %{},
  error: nil
}
```

Normalization does not erase meaningful differences. Shared semantics have
stable fields and event names; optional data is described by provider
capabilities; records without a safe canonical mapping use `:provider_event`.
See [Normalization and the data model](guides/normalization_and_data_model.md).

## Choose an API

| Need | API | Result |
| --- | --- | --- |
| Wait for one request | `Jido.Harness.run/3` | `RunResult` |
| Start work and reattach later | `Jido.Harness.Run` | stable `run_id` |
| Hold a multi-turn conversation | `Jido.Harness.Session` | stable `session_id` and `turn_id` values |
| Supervise a local executable | `Jido.Harness.Process` | stable `process_id` |

Detached run example:

```elixir
{:ok, run_id} =
  Jido.Harness.Run.start(:codex, %{
    prompt: "Review the current branch",
    cwd: File.cwd!(),
    sandbox_mode: :read_only
  })

{:ok, events} = Jido.Harness.Run.stream(run_id)
Enum.each(events, &IO.inspect/1)

{:ok, %Jido.Harness.RunResult{} = result} =
  Jido.Harness.Run.await(run_id, 600_000)
```

Interactive session example:

```elixir
{:ok, session_id} =
  Jido.Harness.Session.start(:codex, %{cwd: File.cwd!()})

{:ok, first_id} =
  Jido.Harness.Session.send_message(session_id, "Summarize this project")

{:ok, %Jido.Harness.TurnResult{} = first} =
  Jido.Harness.Session.await(session_id, first_id, 600_000)

{:ok, next_id} =
  Jido.Harness.Session.follow_up(session_id, "Now identify the main risk")

{:ok, %Jido.Harness.TurnResult{} = next} =
  Jido.Harness.Session.await(session_id, next_id, 600_000)

:ok = Jido.Harness.Session.close(session_id)
```

## Documentation

Start with:

- [Overview](guides/overview.md)
- [Getting started](guides/getting_started.md)
- [Choosing a workflow](guides/choosing_a_workflow.md)
- [Providers and capabilities](guides/providers.md)
- [Normalization and the data model](guides/normalization_and_data_model.md)
- [Version 3 migration](docs/migration_v3.md)
- [ExMCP ACP boundary](docs/decisions/exmcp-acp-boundary.md)

Then follow the workflow guides for
[one-shot requests](guides/one_shot_requests.md),
[detached runs](guides/detached_runs.md),
[interactive sessions](guides/interactive_sessions.md), or
[managed processes](guides/managed_processes.md).

## Livebooks

The repository includes runnable notebooks:

- [One-shot requests](livebooks/01_one_shot_requests.livemd)
- [Detached runs, streams, and replay](livebooks/02_detached_runs.livemd)
- [Interactive sessions and managed processes](livebooks/03_sessions_and_processes.livemd)

Provider examples are live and may consume usage. The managed-process example
is entirely local.

## Testing provider integrations

Jido.Harness ships opt-in ExUnit contracts without starting ExUnit itself:

```elixir
defmodule MyCodexIntegrationTest do
  use Jido.Harness.IntegrationCase, provider: :codex
  harness_contract_tests()
end
```

See the [testing guide](guides/testing.md) for deterministic, smoke, contract,
lifecycle, interactive, and soak profiles.

## Scope

Jido.Harness is a normalization and lifecycle runtime. It is not a durable job
system, provider router, workspace provisioner, TUI automation layer, or retry
engine. It does not depend on `jido`, `jido_shell`, Sprites, Splode, provider
SDKs, or generic subprocess wrappers.

See the [dependency policy](docs/dependency_policy.md) for the runtime boundary.
