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
| `[:jido, :harness, :session, :start]` | `system_time` | `session_id`, `provider`, `protocol` |
| `[:jido, :harness, :session, :event]` | `count` | `session_id`, `provider`, `type` |
| `[:jido, :harness, :session, :stop]` | `count` | `session_id`, `provider`, `protocol`, `status` |
| `[:jido, :harness, :adapter, :start]` | `system_time` | `run_id`, `provider`, `adapter` |
| `[:jido, :harness, :adapter, :stop]` | native `duration` | `run_id`, `provider`, `adapter`, `status` |
| `[:jido, :harness, :replay_store, :append]` | native `duration`, `retained_bytes`, `retained_events` | `adapter`, resource `kind`, storage `status` |
| `[:jido, :harness, :replay_store, :read]` | native `duration`, `returned_records`, `gaps`, `bytes` | `adapter`, resource `kind`, storage `status` |
| `[:jido, :harness, :replay_store, :error]` | `count` | `adapter`, `operation` |
| `[:jido, :harness, :journal, :error]` | `count` | failure `reason` and sometimes `owner_id` |
| `[:jido, :harness, :journal, :overflow]` | removed `bytes` | journal directory and next cursor |
| `[:jido, :harness, :journal, :replay]` | native `duration`, `decoded_records`, `read_bytes`, `segments_opened`, `returned_records` | `journal_dir`, `cursor`, `limit`, `read_failed?` |

Process event names end in `:started`, `:stdout`, `:stderr`, `:exited`,
`:failed`, `:cancelled`, or `:timed_out`.

Journal replay measurements describe one disk replay attempt. `read_bytes`
counts bytes passed to the JSON decoder, not physical disk reads. File read
buffers and the OS cache can change the physical work. `decoded_records`
includes skipped and malformed lines. A successful caught-up poll reports zero
decodes, zero bytes, and zero opened segments. `read_failed?` marks an attempt
that used the memory fallback. Resources without a working disk journal use
memory directly and do not emit this event.

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

Replay-store telemetry covers all adapters and fallback. Read gap counts refer
to ranges, not individual missing sequences. Journal telemetry remains specific
to file I/O. Monitor replay-store errors to include open failures and custom
adapters. Retained measurements use the adapter budget measure, not actual VM
memory. See [Replay stores](../replay_stores.md).
