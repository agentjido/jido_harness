# Canonical event reference

`Jido.Harness.Event` is the normalized provider-event envelope used by finite
runs and interactive sessions. Each event contains provider identity, stable
harness identity, sequence, timestamp, a string-keyed payload, and optional raw
provider data.

## Run lifecycle

| Event | Meaning |
| --- | --- |
| `:run_started` | The supervised run began provider execution |
| `:run_completed` | The run completed successfully |
| `:run_failed` | The run reached a failed terminal state |
| `:run_cancelled` | The run reached a cancelled terminal state |

Exactly one run-terminal event is emitted for every terminal run.

## Session lifecycle

| Event | Meaning |
| --- | --- |
| `:session_started` | The harness session worker started |
| `:session_ready` | The selected transport opened successfully |
| `:session_idle` | The session can accept an idle message |
| `:session_closed` | The session closed gracefully |
| `:session_failed` | The session failed |
| `:session_cancelled` | The session was forcibly cancelled |

Exactly one session-terminal event is emitted for every terminal session.

## Turn and queue lifecycle

| Event | Meaning |
| --- | --- |
| `:input_accepted` | A turn request was accepted |
| `:turn_queued` | A follow-up was placed in the FIFO queue |
| `:queue_changed` | The queued-turn count changed |
| `:turn_started` | Provider execution began for a turn |
| `:turn_completed` | The turn completed successfully |
| `:turn_failed` | The turn failed |
| `:turn_interrupted` | The active turn was interrupted |

Every accepted turn receives exactly one turn-terminal event.

## Provider output

| Event | Meaning |
| --- | --- |
| `:output_text_delta` | Incremental assistant text |
| `:output_text_final` | Provider-declared final assistant text |
| `:thinking_delta` | Incremental reasoning/thinking data |
| `:command_output_delta` | Incremental output from a provider command/tool |
| `:tool_call` | Normalized tool invocation |
| `:tool_result` | Normalized result of a tool invocation |
| `:file_change` | Structured file-change data |
| `:plan_updated` | Structured plan state changed |
| `:usage` | Provider-supplied usage data |

These events are capability-dependent. A provider that cannot supply a
canonical value does not fabricate it.

## Interaction events

| Event | Meaning |
| --- | --- |
| `:approval_requested` | A transport requested an application decision |
| `:approval_resolved` | The approval request was resolved |

Approval exchange is available only on transports that declare it.

## Provider events and replay gaps

`:provider_event` preserves a record or lifecycle condition that has no safe
canonical event type. Inspect `payload["kind"]` before interpreting it.

Run and session replay gaps are represented as:

```elixir
%Jido.Harness.Event{
  type: :provider_event,
  payload: %{
    "kind" => "replay_gap",
    "available_from" => first_available_sequence
  }
}
```

The optional `raw` field can retain the original provider value in memory. Raw
provider values are not persisted to the JSONL journal.

## Event identity

Finite-run events set `run_id`; session events set `session_id` and may also set
`turn_id` or `request_id`. `provider_session_id` remains the provider's resume
identifier and is not interchangeable with any harness ID.

Sequence values are monotonically increasing within one run or session. They
are not global across resources.

## Payload stability

The event envelope and canonical type names are stable. Payload keys are
string-normalized. Fields with shared semantics are canonical, but provider
extensions or incomplete mappings may remain provider-dependent. Portable code
should branch on declared capabilities and ignore unknown payload keys.

## Process events

Local processes use the separate `Jido.Harness.ProcessEvent` type:

- `:started`
- `:stdout`
- `:stderr`
- `:exited`
- `:failed`
- `:cancelled`
- `:timed_out`
- `:replay_gap`

Process events use `process_id`, `sequence`, `stream`, `data`, and `metadata`
rather than the provider event envelope.
