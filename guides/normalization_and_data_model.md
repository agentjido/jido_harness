# Normalization and the data model

Normalization is the central Jido.Harness API promise. Applications should be
able to change providers without replacing their lifecycle code or teaching
every consumer how to parse a different CLI protocol.

Jido.Harness therefore translates provider-specific inputs and outputs into a
small set of validated Elixir structs.

## Boundary types

| Boundary | Normalized type |
| --- | --- |
| Finite request | `Jido.Harness.RunRequest` |
| Session configuration | `Jido.Harness.SessionRequest` |
| One session turn | `Jido.Harness.TurnRequest` |
| Terminal run response | `Jido.Harness.RunResult` |
| Terminal turn response | `Jido.Harness.TurnResult` |
| Provider activity | `Jido.Harness.Event` |
| Resource snapshots | `RunInfo`, `SessionInfo`, `ProcessInfo` |
| Provider discovery | `AdapterSpec`, `ProviderStatus`, capability structs |
| Failures | `Jido.Harness.Error` |
| Local process activity | `Jido.Harness.ProcessEvent` |

The structs use Zoi schemas for construction and validation. Adapters return
these types at their public boundary rather than returning SDK structs or
arbitrary provider maps.

## A normalized response

Finite runs and session turns have separate response types because their
identity and terminal statuses differ. Their shared output vocabulary is
deliberately consistent:

```elixir
%Jido.Harness.RunResult{
  run_id: "run_...",
  provider: :codex,
  provider_session_id: "provider-thread-id",
  status: :completed,
  text: "normalized final text",
  text_truncated?: false,
  usage: %{},
  events: [%Jido.Harness.Event{}, ...],
  metadata: %{},
  error: nil
}
```

```elixir
%Jido.Harness.TurnResult{
  session_id: "session_...",
  turn_id: "turn_...",
  provider: :pi,
  provider_session_id: "provider-session-id",
  status: :completed,
  text: "normalized final text",
  text_truncated?: false,
  usage: %{},
  events: [%Jido.Harness.Event{}, ...],
  metadata: %{},
  error: nil
}
```

Consumers can rely on the top-level identity, status, text, truncation flag,
events, and metadata fields without knowing which CLI produced them.

## Canonical events

Provider records converge on one `Jido.Harness.Event` envelope:

```elixir
%Jido.Harness.Event{
  type: :output_text_final,
  run_id: "run_...",
  session_id: nil,
  provider: :claude,
  provider_session_id: "...",
  turn_id: nil,
  sequence: 4,
  timestamp: "2026-01-01T00:00:00Z",
  payload: %{"text" => "normalized final text"},
  raw: nil
}
```

Canonical event types cover:

- run, session, and turn lifecycle;
- accepted and queued input;
- text and thinking output;
- command output, tool calls, and tool results;
- file changes and plan updates;
- usage;
- approvals and queue changes;
- provider records with no canonical mapping.

Event payload keys are strings. The envelope and canonical event name are
stable; payload fields are canonical where the adapter can map them faithfully.
See the [canonical event reference](../docs/event_reference.md).

## Three stability levels

### Stable normalized contract

These are provider-independent package semantics:

- harness IDs and provider identity;
- lifecycle states and terminal statuses;
- event sequence and timestamp;
- canonical event names;
- final text and truncation indication;
- normalized error category and message;
- await, cancellation, replay, and pruning behavior.

### Capability-dependent normalized data

Some canonical data exists only when the provider supplies it reliably:

- thinking events;
- tool call and result records;
- usage fields;
- structured file changes;
- attachments and multimodal content;
- approval exchange, steering, and dynamic configuration.

Absence is not replaced with invented values. Capability declarations tell a
caller what the adapter or selected session transport can represent.

### Provider-specific escape hatch

Some provider concepts do not have shared semantics:

- Request-only extensions belong under `provider_options`.
- Unknown or loss-sensitive output becomes a `:provider_event`.
- `Event.raw` may retain the original provider value in memory.

Raw provider values are not persisted to disk journals. Code that consumes
`provider_options`, `:provider_event`, or `raw` is intentionally provider-aware
and receives no cross-provider portability guarantee.

## Normalization is not equalization

A managed session that resumes a new CLI process per turn is not labeled as a
native persistent session. A provider that cannot enforce workspace-only writes
does not advertise that sandbox value. An adapter that cannot extract reliable
usage does not fabricate token counts.

`AdapterSpec`, `Capabilities`, `SessionTransportSpec`, and
`InteractionCapabilities` make these differences part of the API rather than
leaving them as documentation footnotes.

## Errors at the boundary

Setup and API failures use `Jido.Harness.Error` with a normalized category:

- `:validation`
- `:configuration`
- `:provider`
- `:process`
- `:execution`
- `:timeout`
- `:cancelled`
- `:internal`

A terminal provider failure can also be represented by an `{:ok, result}` whose
status is `:failed`. This distinguishes "the harness returned the terminal
response" from "the API operation itself could not return a response." Always
inspect terminal status.

## Metadata and usage

`metadata` is application-supplied, in-memory context. Do not place secrets in
it. `usage` is a normalized map because providers expose different units and
levels of detail. Consumers should read known keys defensively and consult the
provider capability declaration before requiring usage data.

## Text retention

Result text is a bounded tail. If `text_truncated?` is true, `text` contains the
newest retained content, while cursor replay remains the source for the full
retained event sequence.
