# Configuration reference

Jido.Harness reads application configuration under the `:jido_harness` key.
Request values override configured defaults.

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

The map merges over the nine built-ins. A matching key explicitly overrides a
built-in adapter. Each value must implement the v2 `Jido.Harness.Adapter`
contract.

## `:provider_config`

```elixir
config :jido_harness,
  provider_config: %{
    codex: %{
      request_defaults: %{
        sandbox_mode: :workspace_write,
        approval_mode: :prompt
      },
      session_defaults: %{
        sandbox_mode: :workspace_write,
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
    term_grace_ms: 5_000
  }
```

| Key | Default | Meaning |
| --- | --- | --- |
| `journal_dir` | user cache directory | Base directory for resource journals |
| `segment_bytes` | 8 MiB | Journal rotation segment size |
| `disk_limit_bytes` | 256 MiB | Maximum journal bytes per resource |
| `terminal_ttl_ms` | 24 hours | Age at which terminal resources are pruned |
| `retention_sweep_ms` | 60 seconds | Retention-worker sweep interval |
| `cancel_grace_ms` | 5 seconds | SIGINT-to-SIGTERM delay |
| `term_grace_ms` | 5 seconds | SIGTERM-to-SIGKILL delay |

Per-resource retention can set `journal_dir`, `memory_bytes`, `segment_bytes`,
and `disk_limit_bytes`. Per-resource values override process-manager journal
defaults. Memory defaults to 1 MiB.

## Test-only process driver

The `:process_driver` key replaces the subprocess driver and exists for
deterministic tests. Production applications should use the default erlexec
driver.

## Runtime environment

Provider executables and cached authentication are resolved in the operating
system environment visible to the BEAM. Application configuration does not
inherit an interactive shell's `PATH` automatically. Releases, GUI runtimes,
containers, and service managers must expose the CLI executable and credential
environment explicitly.
