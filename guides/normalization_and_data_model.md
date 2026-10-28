# Normalization and data model

Harness converts ACP activity into validated requests, results, errors, and
native Jido Signals.

## Boundary types

| Boundary | Type |
| --- | --- |
| Finite request | `Jido.Harness.RunRequest` |
| Session configuration | `Jido.Harness.SessionRequest` |
| Session turn | `Jido.Harness.TurnRequest` |
| Terminal run response | `Jido.Harness.RunResult` |
| Terminal turn response | `Jido.Harness.TurnResult` |
| Resource activity | `Jido.Signal` |
| Resource snapshots | `RunInfo`, `SessionInfo`, `ProcessInfo` |
| Provider discovery | `AdapterSpec`, `ProviderStatus`, capability structs |
| API failure | `Jido.Harness.Error` |

Public Harness structs use Zoi schemas. Their `new/1` and `new!/1` functions
validate values.

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
| `signals` | Retained in-memory Signal tail |
| `metadata` | Application-supplied context |
| `error` | Failure information, when present |

`RunResult` adds `run_id`. `TurnResult` adds `session_id` and `turn_id`.

## Signals

Harness facts are fixed native Signal modules. For example:

```elixir
{:ok, signal} =
  Jido.Harness.Signal.Output.TextFinal.new(
    %{
      "run_id" => "run_example",
      "provider" => "codex",
      "sequence" => 4,
      "payload" => %{"text" => "normalized final text"},
      "metadata" => %{}
    },
    source: "urn:jido:harness:run:example"
  )
```

Sequences increase inside one resource. They are not global. Read the
[Signal reference](reference/signal_reference.md) for the full inventory.

## Stability

Harness keeps resource IDs, provider identity, terminal status, ordering,
await, cancellation, replay, and pruning common across providers. Thinking,
tool activity, usage, file changes, attachments, approvals, and configuration
depend on provider capabilities. Provider-specific values use
`jido.harness.provider.message`.

Harness does not invent missing provider data. Consumers must ignore unknown
payload keys that they do not use.

## Raw ACP data

Decoded ACP envelopes are private adapter messages. They are not part of the
public Signal contract and are not stored. A provider-specific integration can
use normalized `provider.message` payloads or its own adapter boundary.

## Errors and retention

`Jido.Harness.Error` classifies validation, configuration, provider, process,
execution, timeout, cancellation, and internal failures. An outer
`{:ok, result}` means a terminal result exists; always inspect `result.status`.

Final text and Signal tails are bounded. If `text_truncated?` is true, replay
can return retained Signals, but it cannot restore rotated journal segments.
Treat prompts, output, and metadata as sensitive.
