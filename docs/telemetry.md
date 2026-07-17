# Telemetry reference

Jido.Harness emits lifecycle telemetry directly through `:telemetry`. It does
not wrap telemetry in Jido Actions or Signals.

## Events

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:jido, :harness, :process, event_type]` | `count` | `process_id` |
| `[:jido, :harness, :run, :start]` | `system_time` | `run_id`, `provider` |
| `[:jido, :harness, :run, :event]` | `count` | `run_id`, `provider`, `type` |
| `[:jido, :harness, :run, :stop]` | `count` | `run_id`, `provider`, `status` |
| `[:jido, :harness, :session, :start]` | `system_time` | `session_id`, `provider`, `transport` |
| `[:jido, :harness, :session, :event]` | `count` | `session_id`, `provider`, `type` |
| `[:jido, :harness, :session, :stop]` | `count` | `session_id`, `provider`, `transport`, `status` |
| `[:jido, :harness, :adapter, :start]` | `system_time` | `run_id`, `provider`, `adapter` |
| `[:jido, :harness, :adapter, :stop]` | native `duration` | `run_id`, `provider`, `adapter`, `status` |
| `[:jido, :harness, :journal, :error]` | `count` | failure `reason` and sometimes `owner_id` |
| `[:jido, :harness, :journal, :overflow]` | removed `bytes` | journal directory and next cursor |

Process event names end in `:started`, `:stdout`, `:stderr`, `:exited`,
`:failed`, `:cancelled`, or `:timed_out`.

## Attach a handler

```elixir
events = [
  [:jido, :harness, :run, :start],
  [:jido, :harness, :run, :stop],
  [:jido, :harness, :session, :start],
  [:jido, :harness, :session, :stop],
  [:jido, :harness, :journal, :error]
]

:telemetry.attach_many(
  "my-app-jido-harness",
  events,
  &MyApp.HarnessTelemetry.handle_event/4,
  %{}
)
```

```elixir
defmodule MyApp.HarnessTelemetry do
  require Logger

  def handle_event(event, measurements, metadata, _config) do
    Logger.info("harness event",
      event: Enum.join(event, "."),
      measurements: measurements,
      provider: metadata[:provider],
      run_id: metadata[:run_id],
      session_id: metadata[:session_id]
    )
  end
end
```

Keep telemetry handlers fast. Export or aggregate asynchronously when the
backend can block.

## Event telemetry versus normalized events

Telemetry describes runtime operation and is intentionally compact.
`Jido.Harness.Event` contains the ordered provider activity intended for
streaming and replay. Do not attempt to reconstruct a run response from
telemetry; consume the resource event journal instead.

## Sensitive data boundary

Built-in metadata never includes prompts, environment values, credentials, or
complete argv. Application handlers and exporters should preserve that rule.
Avoid attaching resource metadata directly unless the application has already
classified and redacted it.

## Recommended operational signals

- Count run and session terminal statuses by provider.
- Measure adapter duration from the native duration measurement.
- Alert on journal errors.
- Track journal overflow when complete replay matters.
- Track long-running or idle resources from lifecycle lists and timestamps.
