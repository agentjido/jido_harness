# Jido.Harness

[![Hex.pm](https://img.shields.io/hexpm/v/jido_harness.svg)](https://hex.pm/packages/jido_harness)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_harness/)
[![CI](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_harness.svg)](https://github.com/agentjido/jido_harness/blob/main/LICENSE)

`Jido.Harness` 2.0 is the single supervised Elixir runtime for Amp, Claude Code,
Codex, Gemini CLI, Kimi Code, OpenCode, Grok, and Z.AI. It normalizes provider
requests, events, results, errors, status checks, installation recipes, and
cancellation while preserving provider-specific options under
`provider_options`.

Runs and managed OS processes belong to the application supervision tree. They
survive the process that started or streamed them and can be reattached by ID.
They intentionally do not survive a BEAM or host restart.

## Installation

```elixir
def deps do
  [
    {:jido_harness, "~> 2.0"}
  ]
end
```

The eight built-in adapters are registered automatically. A providerless request
requires an explicit default:

```elixir
config :jido_harness,
  default_provider: :codex,
  provider_config: %{
    codex: %{
      request_defaults: %{sandbox_mode: :workspace_write}
    }
  }
```

## Runs

Start a detached run and reattach later:

```elixir
{:ok, run_id} =
  Jido.Harness.start(:codex, %{
    prompt: "Fix the failing test",
    cwd: "/absolute/path/to/repo",
    runtime_timeout_ms: :infinity,
    idle_timeout_ms: :infinity,
    approval_mode: :prompt,
    sandbox_mode: :workspace_write
  })

{:ok, events} = Jido.Harness.stream(run_id)
Enum.each(events, &IO.inspect/1)

{:ok, result} = Jido.Harness.await(run_id, 7_200_000)
```

An await timeout returns `{:error, :timeout}` without cancelling the run.

For a blocking convenience call:

```elixir
{:ok, %Jido.Harness.RunResult{} = result} =
  Jido.Harness.run_sync(:claude, "Explain this repository",
    cwd: File.cwd!(),
    await_timeout: 600_000
  )
```

Resume semantics use the provider session ID, which remains separate from the
harness run ID:

```elixir
Jido.Harness.start(:grok, %{
  prompt: "Continue the refactor",
  session_id: provider_session_id
})
```

Unknown normalized and provider-specific keys are rejected. Provider escape
hatches are nested and cannot shadow normalized fields:

```elixir
Jido.Harness.start(:grok, %{
  prompt: "Review this change",
  provider_options: %{
    allow_rules: ["Bash(git *)"],
    deny_rules: ["Bash(git push *)"]
  }
})
```

Z.AI is exposed as `:zai` through its officially supported Claude Code
integration. The adapter maps `ZAI_API_KEY` to the child process's
`ANTHROPIC_AUTH_TOKEN`, sets the Z.AI endpoint, and keeps long-run API timeouts
aligned with the harness runtime:

```elixir
Jido.Harness.start(:zai, %{
  prompt: "Review the current branch",
  model: "glm-5.2",
  cwd: File.cwd!()
})
```

Kimi Code is exposed as `:kimi` through its official non-interactive
`stream-json` interface. Cached OAuth and `config.toml` credentials work
unchanged. For ephemeral API-key runs, use Kimi's documented
`KIMI_MODEL_NAME` and `KIMI_MODEL_API_KEY` environment channel:

```elixir
Jido.Harness.start(:kimi, %{
  prompt: "Review the current branch",
  model: "k3",
  cwd: File.cwd!(),
  runtime_timeout_ms: :infinity
})
```

The adapter disables CLI self-updates, persistent cron creation, and detached
background survival for harness-owned runs. Model selection, session resume,
additional directories, reasoning effort, and skills directories remain
available through normalized fields or `provider_options`.

## Managed processes

Built-in CLI adapters never interpolate a shell command. The public process
manager accepts an executable and argv:

```elixir
{:ok, process_id} =
  Jido.Harness.start_process(%{
    executable: "my-cli",
    argv: ["--format", "json"],
    cwd: File.cwd!(),
    stdin: true,
    pty: false,
    runtime_timeout_ms: :infinity,
    idle_timeout_ms: :infinity
  })

:ok = Jido.Harness.send_input(process_id, "input\n")
:ok = Jido.Harness.close_input(process_id)
{:ok, process_info} = Jido.Harness.await_process(process_id, 60_000)
```

Output is cursor-addressable through `stream_process/2` and `replay_process/2`.
Cancellation targets the complete process group and escalates from SIGINT to
SIGTERM to SIGKILL. See [process management](docs/process_management.md).

## Opt-in integration contracts

The package ships reusable ExUnit support without starting ExUnit:

```elixir
defmodule MyCodexIntegrationTest do
  use Jido.Harness.IntegrationCase, provider: :codex
  harness_contract_tests()
end
```

Integration tests are excluded by default. Run live profiles explicitly:

```console
mix jido_harness.integration --providers codex,grok --profile smoke
mix jido_harness.integration --providers codex --profile lifecycle --strict
mix jido_harness.integration --profile soak
```

See [integration testing](docs/integration_testing.md) and the
[v2 migration guide](docs/migration_v2.md).

## Scope

`jido_shell` is not a harness and is neither changed nor used by this package.
Jido.Harness has no dependency on `jido`, `jido_shell`, Sprites, or Splode.
