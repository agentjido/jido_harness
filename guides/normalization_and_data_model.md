# Normalization and the data model

Harness converts ACP activity into validated Elixir structs. Common fields
let an application use the same lifecycle code across providers. Optional
data still depends on the selected ACP profile.

## Boundary types

| Boundary | Type |
| --- | --- |
| Finite request | `Jido.Harness.RunRequest` |
| Session configuration | `Jido.Harness.SessionRequest` |
| Session turn | `Jido.Harness.TurnRequest` |
| Terminal run response | `Jido.Harness.RunResult` |
| Terminal turn response | `Jido.Harness.TurnResult` |
| Provider activity | `Jido.Harness.Event` |
| Resource snapshots | `RunInfo`, `SessionInfo`, `ProcessInfo` |
| Provider discovery | `AdapterSpec`, `ProviderStatus`, capability structs |
| API failure | `Jido.Harness.Error` |
| Local process activity | `Jido.Harness.ProcessEvent` |

Public structs use Zoi schemas for construction and validation. Their
`new/1` and `new!/1` functions validate values. Plain struct construction
does not perform schema validation.

## Results

Runs and turns share these fields:

| Field | Meaning |
| --- | --- |
| `provider` | Selected provider atom |
| `provider_session_id` | Provider context or resume ID, when available |
| `status` | Terminal outcome |
| `text` | Bounded final text tail |
| `text_truncated?` | Whether earlier final text was omitted |
| `usage` | Provider-supplied normalized usage |
| `events` | Retained in-memory event tail |
| `metadata` | Application-supplied context |
| `error` | Failure information, when present |

`RunResult` adds `run_id` and has statuses `:completed`, `:failed`, and
`:cancelled`. `TurnResult` adds `session_id` and `turn_id` and has statuses
`:completed`, `:failed`, and `:interrupted`.

The `RunResult.structured_output` field is retained in the type, but no
built-in ACP profile supports structured output. Do not infer availability
from the presence of that field.

## Events

`Jido.Harness.Event` has stable identity, type, sequence, timestamp, and a
string-keyed payload:

```elixir
Jido.Harness.Event.new!(
  type: :output_text_final,
  run_id: "run_example",
  provider: :codex,
  sequence: 4,
  payload: %{"text" => "normalized final text"}
)
```

Sequences increase within one resource. They are not global.
Session events can also identify a turn or an approval request.
The [event reference](reference/event_reference.md) defines the complete event
inventory, raw-message boundary, and provider configuration records.

## Stability levels

| Level | Contract |
| --- | --- |
| Common lifecycle | Harness IDs, provider identity, terminal statuses, ordering, await, cancellation, replay, and pruning |
| Optional normalized data | Thinking, tool activity, usage, file changes, attachments, approvals, and configuration, when the ACP profile supports them |
| Provider extensions | `provider_options` input and `:provider_event` output with provider-specific semantics |

Harness does not invent missing token counts or other provider data. Unknown
payload keys can appear as a provider evolves. Portable consumers should
check capabilities and ignore fields they do not use.

## Raw ACP messages

`Event.raw` can retain a decoded ACP message in memory. It does not retain
original JSON bytes. For a native ACP provider, the message comes from that
provider. For a separate ACP adapter, it comes from the adapter after
translation. Native fields the adapter omits are unavailable.

Raw messages are not persisted. Journal-backed replay returns `raw: nil`.
Code that depends on raw fields or provider extensions needs its own
provider-specific compatibility checks.

## Errors

Setup and API failures can return `Jido.Harness.Error` with categories
`:validation`, `:configuration`, `:provider`, `:process`, `:execution`,
`:timeout`, `:cancelled`, or `:internal`. Lifecycle calls can also return
atoms such as `:timeout`, `:not_found`, or `:busy`.

An outer `{:ok, result}` tuple means a terminal response was returned. The
task can still have failed. Always inspect `result.status`.
See [Runs](runs.md#await-and-handle-the-result) for a complete result branch.

## Retention and sensitive data

Final text and result events are bounded tails. If `text_truncated?` is true,
replay provides the full retained event sequence. It cannot restore rotated
journal segments.

Treat prompts, output, and metadata as sensitive. Metadata is in-memory
application context; do not place credentials in it. Read
[Streaming, replay, and retention](streaming_replay_and_retention.md) and
[Security](security.md) before exporting retained records.
