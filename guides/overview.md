# Overview

Jido.Harness is a normalization and lifecycle layer for CLI coding agents. It
gives an Elixir application one way to start provider work, observe it, retain
its output, and control its lifetime without adopting a provider SDK or parsing
provider-specific JSON.

The package has two complementary responsibilities:

1. **Normalize provider protocols.** Provider requests and records become
   validated Jido.Harness requests, events, results, statuses, capabilities,
   and errors.
2. **Own runtime resources.** Runs, sessions, and local processes live under
   the application supervision tree rather than under whichever caller happens
   to start or consume them.

## The resource model

The public API is organized around three resource types.

| Resource | Use it for | Stable identity | Terminal value |
| --- | --- | --- | --- |
| `Jido.Harness.Run` | One finite provider execution | `run_id` | `Jido.Harness.RunResult` |
| `Jido.Harness.Session` | A multi-turn provider conversation | `session_id`, `turn_id` | `Jido.Harness.TurnResult` per turn |
| `Jido.Harness.Process` | One structured local OS process | `process_id` | `Jido.Harness.ProcessInfo` |

`Jido.Harness.run/3` is a convenience over the run lifecycle: it starts a
supervised run, waits for its result, and returns that result directly.

Every resource can be inspected independently of its creator. Detached runs
and sessions can be listed and reattached by ID. Their event streams are
cursor-driven, so a slow consumer does not cause an unbounded producer mailbox.

## The normalization boundary

Provider-specific values enter and leave only at explicit edges:

```text
provider selection and normalized request
                    │
                    ▼
 RunRequest / SessionRequest / TurnRequest
                    │
                    ▼
       adapter + supervised CLI process
                    │
                    ▼
       ordered Jido.Harness.Event values
                    │
                    ▼
 RunResult / TurnResult / Jido.Harness.Error
```

Shared semantics have stable names and types. Capability-dependent data is
present only when a provider can supply it. Input escape hatches live under
`provider_options`; output without a safe canonical mapping uses
`:provider_event` and `Event.raw`.

This is normalization, not forced equivalence. Jido.Harness does not claim that
managed follow-up turns are native protocol turns, that unavailable usage is
zero, or that all sandbox modes mean the same thing on every CLI. Capability
metadata makes those differences visible and unsupported options fail before
provider dispatch.

Read [Normalization and the data model](normalization_and_data_model.md) for
the stability boundary.

## Runtime guarantees

Jido.Harness establishes these package-level guarantees:

- A run, session, or process is application-owned rather than caller-owned.
- Each resource receives a stable harness ID distinct from provider resume IDs.
- Events are sequenced within their resource.
- Each finite run receives exactly one run-terminal event.
- Each accepted session turn receives exactly one turn-terminal event.
- Each session receives exactly one session-terminal event.
- An await timeout stops waiting but does not cancel the underlying resource.
- Cancellation targets the complete managed process group.
- Output retention is bounded in memory and on disk.
- Unknown options are rejected rather than silently discarded.
- Built-in adapters launch an executable with argv and never interpolate a
  shell command.

These are in-process guarantees. Resources and journals are not reconstructed
after a BEAM or host restart.

## Capability map

| Capability | Entry point |
| --- | --- |
| Discover providers | `Jido.Harness.providers/0` |
| Check installation and readiness | `Jido.Harness.status/1` |
| Preview or perform an installation recipe | `Jido.Harness.install/2` |
| Make a blocking request | `Jido.Harness.run/3` |
| Detach, stream, replay, cancel, or prune a run | `Jido.Harness.Run` |
| Hold multi-turn context | `Jido.Harness.Session` |
| Manage a shell-free subprocess | `Jido.Harness.Process` |
| Observe normalized activity | `Jido.Harness.Event` and telemetry |
| Verify a provider integration | Mix tasks and `Jido.Harness.IntegrationCase` |
| Add or override a provider | `Jido.Harness.Adapter` and registry configuration |

## What Jido.Harness does not do

Jido.Harness does not select a provider automatically, retry billable work,
provision workspaces, automate provider TUIs, or provide durable distributed
execution. It is also independent of `jido`, `jido_shell`, Sprites, and Splode.

## Where to go next

1. Follow [Getting started](getting_started.md) to verify one CLI and make one
   normalized request.
2. Use [Choosing a workflow](choosing_a_workflow.md) to select the right
   lifecycle API.
3. Read the guide for [one-shot requests](one_shot_requests.md),
   [detached runs](detached_runs.md),
   [interactive sessions](interactive_sessions.md), or
   [managed processes](managed_processes.md).
