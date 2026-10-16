# Configuration reference

Jido.Harness reads application configuration under the `:jido_harness` key.
Request values override configured defaults.

Set these values in the host application's configuration. The Harness
repository's `config/config.exs` only configures local logging and repository
tools. Mix does not load a dependency's configuration files into the host
application.

## `:default_provider`

```elixir
config :jido_harness, default_provider: :codex
```

The value must be a registered provider atom. It is used only when a request
does not select a provider explicitly.

## `:providers`

```elixir
config :jido_harness,
  providers: %{
    internal: MyApp.InternalHarnessAdapter,
    codex: MyApp.CodexOverride
  }
```

The map merges over the eleven built-ins. A matching key explicitly overrides a
built-in adapter. Each value must implement the v3 `Jido.Harness.Adapter`
contract.

## `:provider_config`

```elixir
config :jido_harness,
  provider_config: %{
    codex: %{
      acp_path: "/opt/acp/bin/codex-acp",
      request_defaults: %{
        sandbox_mode: :workspace_write,
        runtime_timeout_ms: 300_000
      },
      session_defaults: %{
        sandbox_mode: :workspace_write,
        approval_mode: :prompt,
        turn_runtime_timeout_ms: 600_000
      },
      retention: %{
        memory_bytes: 2 * 1_024 * 1_024,
        disk_limit_bytes: 512 * 1_024 * 1_024
      }
    }
  }
```

Provider configuration is supplied to adapter callbacks and supports these
harness-owned keys:

| Key | Use |
| --- | --- |
| `acp_path` | Override the `ACPAgentSpec` executable for runs and sessions |
| `request_defaults` | Defaults merged into finite `RunRequest` values |
| `session_defaults` | Defaults merged into `SessionRequest` values |
| `retention` | Default run and session memory/journal limits |

Adapter-specific configuration may use additional keys. An explicit request
overrides request/session defaults. Explicit session retention overrides
provider retention for that session.

Finite request precedence is:

1. adapter `AdapterSpec.request_defaults`;
2. configured `provider_config[provider].request_defaults`;
3. explicit request values.

`cli_path` selects the base CLI for readiness checks. `acp_path` selects the
executable that performs model work.

## `:acp_max_frame_bytes`

```elixir
config :jido_harness, :acp_max_frame_bytes, 128 * 1_024 * 1_024
```

The largest ACP message, in bytes, that the harness sends or reads;
the default is 1 MiB. An ACP message is one line of JSON, and an image
travels inside one as base64: a prompt with a screenshot attached, or a tool
result that read one, can exceed the default, which ends the session.
Applications that send or read images should raise it. The limit stays in
place so that an agent that never ends its line cannot make the harness hold
unbounded output. It also applies to steering requests. An oversized steering
request is refused before dispatch, and the current turn remains usable.

## `:acp_max_buffer_bytes`

The complete ACP frame queue has a byte limit. The default is the larger of
4 MiB and four times `:acp_max_frame_bytes`. The count includes each frame's
bytes plus a 64-byte allowance for queue entries. A configured value must be
at least four times the frame limit; a smaller or invalid value uses the
default. Partial frames have the separate frame limit.

The reader pauses when the complete frame queue reaches half the limit. It
resumes when the queue falls to one quarter. Send, close, and cancellation
requests remain available while the reader is paused. Output that exceeds
the process memory buffer produces an explicit `output_gap` transport failure.
Set `:process_manager` `memory_bytes` for the largest expected ACP output burst.
This bounds retained output; it does not limit the operating system producer's
mailbox traffic.

Session requests also have queue, result, and approval limits. See
[interactive sessions](../interactive_sessions.md#queue-follow-up-turns).

## `:replay_store`

The default is `{Jido.Harness.ReplayStore.File, %{}}`. Set a module and options
map to select another adapter. File options are `journal_dir`, `segment_bytes`,
`disk_limit_bytes`, and `max_events` (default 1,000,000). Memory and ETS options
are `max_bytes` (default 1 MiB) and `max_events` (default 10,000).

Adapters are validated before execution. Legacy process-manager file options
remain supported. See [Replay stores](../replay_stores.md) for precedence,
fallback budgets, page limits, and the adapter contract.

## `:process_manager`

```elixir
config :jido_harness,
  process_manager: %{
    journal_dir: "/var/lib/my_app/jido_harness",
    segment_bytes: 8 * 1_024 * 1_024,
    disk_limit_bytes: 256 * 1_024 * 1_024,
    terminal_ttl_ms: 24 * 60 * 60 * 1_000,
    retention_sweep_ms: 60_000,
    cancel_grace_ms: 5_000,
    term_grace_ms: 5_000,
    output_drain_ms: 50
  }
```

| Key | Default | Meaning |
| --- | --- | --- |
| `journal_dir` | user cache directory | Base directory for resource journals |
| `memory_bytes` | 1 MiB | Default process output buffer, including the internal ACP process; per-process retention overrides it |
| `segment_bytes` | 8 MiB | Journal rotation segment size |
| `disk_limit_bytes` | 256 MiB | Maximum journal bytes per resource |
| `terminal_ttl_ms` | 24 hours | Age at which terminal resources are pruned |
| `retention_sweep_ms` | 60 seconds | Retention-worker sweep interval |
| `cancel_grace_ms` | 5 seconds | SIGINT-to-SIGTERM delay |
| `term_grace_ms` | 5 seconds | SIGTERM-to-SIGKILL delay |
| `output_drain_ms` | 50 milliseconds | Quiet period for stdout/stderr already in flight after process exit |

Per-resource retention can set `journal_dir`, `memory_bytes`, `segment_bytes`,
and `disk_limit_bytes`. Per-resource values override process-manager journal
defaults. Memory defaults to 1 MiB.

## Process driver

The harness starts provider processes through the bundled native engine,
except on Windows, where that engine is not built: there it uses a driver
that runs processes through an Erlang port. `.cmd` and `.bat` executables,
which is how npm installs commands, are started through the command
interpreter. A port has no pseudo-terminal, does
not capture standard error separately and cannot close standard input on its
own; signals end the process and its children.

The `:process_driver` key replaces the subprocess driver and exists for
deterministic tests. Production applications should use the default driver.

## Runtime environment

Provider executables and cached authentication are resolved in the operating
system environment visible to the BEAM. Application configuration does not
inherit an interactive shell's `PATH` automatically. Releases, GUI runtimes,
containers, and service managers must expose the CLI executable and credential
environment explicitly.

Run and session requests accept `env_mode: :overlay | :replace`. Overlay mode
preserves the BEAM environment and applies the request entries. Replacement
mode clears the inherited child environment before applying the request
entries; callers must then supply every required value, including `PATH`,
isolated home/temp locations, and scoped credentials.
