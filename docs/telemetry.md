# Telemetry

Jido.Harness emits telemetry directly through `:telemetry`. There is no Jido
Action or Signal wrapper.

## Events

| Event | Measurements | Important metadata |
| --- | --- | --- |
| `[:jido, :harness, :process, event_type]` | `count` | `process_id` |
| `[:jido, :harness, :run, :start]` | `system_time` | `run_id`, `provider` |
| `[:jido, :harness, :run, :event]` | `count` | `run_id`, `provider`, `type` |
| `[:jido, :harness, :run, :stop]` | `count` | `run_id`, `provider`, `status` |
| `[:jido, :harness, :adapter, :start]` | `system_time` | `run_id`, `provider`, `adapter` |
| `[:jido, :harness, :adapter, :stop]` | native `duration` | `run_id`, `provider`, `adapter`, `status` |
| `[:jido, :harness, :journal, :error]` | `count` | `owner_id` or failure reason |
| `[:jido, :harness, :journal, :overflow]` | removed bytes | journal directory, next cursor |

Process event types include `:started`, `:stdout`, `:stderr`, `:exited`,
`:failed`, `:cancelled`, and `:timed_out`.

Telemetry metadata never includes environment values, credentials, prompts, or
complete argv. Consumers should apply the same rule to metadata they attach to
requests.
