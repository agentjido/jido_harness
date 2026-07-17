# Jido.Harness

[![Hex.pm](https://img.shields.io/hexpm/v/jido_harness.svg)](https://hex.pm/packages/jido_harness)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_harness/)
[![CI](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_harness/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_harness.svg)](https://github.com/agentjido/jido_harness/blob/main/LICENSE)

`Jido.Harness` 2.0 is the single supervised Elixir runtime for Amp, Claude Code,
Codex, Gemini CLI, Grok, Kimi Code, OpenCode, Pi, and Z.AI. It normalizes
provider requests, events, results, errors, status checks, installation recipes,
and cancellation while preserving provider-specific options under
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

The nine built-in adapters are registered automatically. A providerless request
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
  provider_session_id: provider_session_id
})
```

## Interactive sessions

Sessions are harness-owned, caller-independent conversations. The harness
`session_id` is used for lookup and lifecycle control; the distinct
`provider_session_id` is the provider's resume token.

```elixir
{:ok, session_id} =
  Jido.Harness.open_session(:codex, %{
    cwd: File.cwd!(),
    sandbox_mode: :workspace_write
  })

{:ok, turn_id} = Jido.Harness.send_message(session_id, "Explain this repository")
{:ok, %Jido.Harness.TurnResult{} = turn} =
  Jido.Harness.await_turn(session_id, turn_id, 600_000)

{:ok, queued_id} = Jido.Harness.follow_up(session_id, "Now identify the main risks")
{:ok, _queued} = Jido.Harness.await_turn(session_id, queued_id, 600_000)
:ok = Jido.Harness.close_session(session_id)
```

`send_message/3` requires an idle session. `follow_up/3` queues FIFO. An
`await_turn/3` timeout does not interrupt the turn. Unsupported steering,
approvals, structured input, or dynamic configuration return a normalized
capability error before provider dispatch.

Run and turn results expose `text_truncated?`. The result text is bounded by the
configured in-memory retention limit; use cursor replay when that flag is true
to consume the complete journaled event sequence.

The default transports use resumed JSONL turns for Amp, Claude, Codex, Gemini,
Grok, and Z.AI; ACP for Kimi and OpenCode; and JSONL RPC for Pi. Session APIs
communicate with headless provider protocols and never automate a provider TUI.

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

Pi is exposed as `:pi` through its official JSON event-stream mode. Pi can route
to any model provider configured through its cached login, API-key environment,
or `models.json`:

```elixir
Jido.Harness.start(:pi, %{
  prompt: "Review the current branch",
  model: "anthropic/claude-sonnet-4-5",
  cwd: File.cwd!(),
  reasoning_effort: :high,
  provider_options: %{
    project_trust: :deny,
    no_context_files: true,
    no_extensions: true,
    no_skills: true
  }
})
```

Pi tools do not display approval prompts, so `:auto_approve` is supported while
`:prompt` and `:auto_edit` are rejected. Pi's documented read-only tool set maps
to `sandbox_mode: :read_only`; `:unrestricted` is also supported, but Pi cannot
enforce workspace-only writes. Use the separate `project_trust` provider option
only when project-local Pi settings, skills, or extensions should be loaded.
Extensions execute with full process access. Harness-managed Pi runs disable
Pi's startup version check and install telemetry.

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

Integration tests are excluded by default. The package exposes two operator
tasks: a non-billable readiness check and a minimal live query:

```console
mix jido_harness.check
mix jido_harness.check --providers codex,kimi --strict
mix jido_harness.chat codex
mix jido_harness.chat codex "Explain this repository in one sentence."
mix jido_harness.chat codex --timeout 120 --json
```

`mix jido_harness.check` reports installation, compatibility, authentication,
readiness, versions, and installation guidance for registered providers. It
never sends an agent prompt. `--strict` rejects unavailable providers and
`--json` emits machine-readable output.

`mix jido_harness.chat` starts one finite run through exactly one registered
provider. With no prompt it asks for exactly `ready`. The task fails on a
provider error or empty response and may consume paid API or subscription usage.

Run the reusable integration contracts directly with ExUnit. Select profiles
and providers through `JIDO_HARNESS_INTEGRATION_PROFILE` and
`JIDO_HARNESS_INTEGRATION_PROVIDERS`; see the integration testing guide.

See [integration testing](docs/integration_testing.md) and the
[v2 migration guide](docs/migration_v2.md).

## Scope

`jido_shell` is not a harness and is neither changed nor used by this package.
Jido.Harness has no dependency on `jido`, `jido_shell`, Sprites, or Splode.
