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

The default transports are SDK sessions for Amp, Claude, Gemini, and Z.AI;
resumed JSONL turns for Codex and Grok; ACP for Kimi and OpenCode; and JSONL RPC
for Pi. Codex app-server is experimental, version-gated, and must be selected
explicitly:

```console
mix jido_harness.chat codex
mix jido_harness.chat codex --transport app_server --format jsonl
```

The chat task accepts ordinary messages plus `/send`, `/follow-up`, `/steer`,
`/interrupt`, `/approve`, `/deny`, `/status`, and `/close`. It communicates with
headless provider protocols and never automates a provider TUI.

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

Integration tests are excluded by default. Run live profiles explicitly:

```console
mix jido_harness.check
mix jido_harness.check --inventory --strict
mix jido_harness.query codex "Explain this repository in one sentence."
mix jido_harness.query all "Reply with exactly: ready" --expect ready
mix jido_harness.check --providers codex,kimi --install

mix jido_harness.integration --providers codex,grok --profile smoke
mix jido_harness.integration --providers codex --profile lifecycle --strict
mix jido_harness.integration --profile interactive --provider all
mix jido_harness.integration --profile interactive --provider all --strict
mix jido_harness.integration --profile soak
```

`mix jido_harness.check` is the single non-billable operator check. By default
it reports installation, compatibility, authentication, smoke readiness, and
installation recipes for registered providers. Use `--install` to run a
provider's explicit npm recipe. Add `--inventory` to run version commands for
the complete local CLI inventory through the managed process runtime. Use
`--tools claude,codex` to select inventory entries, `--strict` to reject
unavailable providers or missing/outdated tools, or `--json` for
machine-readable output. It never sends an agent prompt.

The inventory includes Claude Code, Codex, Amp, Gemini CLI, Antigravity CLI,
Kimi Code, Grok, pi-coding-agent, Aider, Goose, and OpenCode. Antigravity,
Aider, and Goose are probe-only inventory entries: they do not have adapters
and cannot be selected for harness contract or live provider tests.

`mix jido_harness.query` sends an arbitrary prompt through one adapter, a
comma-separated selection, or every registered adapter. Multi-provider queries
run sequentially and print a complete success/failure matrix. Use `--timeout`
for a per-provider limit in seconds, `--cwd`, `--model`, `--provider-session-id`,
`--max-turns`, `--expect` for an exact-response assertion, or `--json` for
machine-readable results. Unlike inventory and readiness checks, query runs can
consume paid API or subscription usage.

`mix jido_harness.integration` owns automated live profiles; there is no second
operator task that forwards to it. Live provider work is therefore always
visibly a `query`, `chat`, or `integration` command and may incur usage.

See [integration testing](docs/integration_testing.md) and the
[v2 migration guide](docs/migration_v2.md).

## Scope

`jido_shell` is not a harness and is neither changed nor used by this package.
Jido.Harness has no dependency on `jido`, `jido_shell`, Sprites, or Splode.
