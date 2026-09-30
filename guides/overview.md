# Overview

Jido.Harness runs coding-agent CLIs from Elixir. It converts Agent Client
Protocol (ACP) activity into common requests, events, results, and errors. It
also owns the processes that execute the work.

Runs, sessions, and local processes belong to the application supervision
tree. They can continue after the caller exits. Their output has bounded
memory and disk retention.

## Choose an API

| Need | API | Guide |
| --- | --- | --- |
| Send one request and wait | `Jido.Harness.run/3` | [Runs](runs.md#wait-for-one-run) |
| Start work and return its ID | `Jido.Harness.Run` | [Runs](runs.md#start-a-detached-run) |
| Keep provider context across turns | `Jido.Harness.Session` | [Interactive sessions](interactive_sessions.md) |
| Manage an arbitrary local executable | `Jido.Harness.Process` | [Managed processes](managed_processes.md) |

The blocking and detached APIs use the same finite-run lifecycle. Use the
detached API when a web request, job process, or progress consumer can end
before the provider finishes.

A session keeps one ACP process open for multiple turns. A managed process
executes a local program without requiring a provider or ACP.

## Resource identities

| ID | Meaning |
| --- | --- |
| `run_id` | One finite Harness execution |
| `session_id` | One Harness conversation |
| `turn_id` | One accepted turn inside a session |
| `process_id` | One managed OS process |
| `provider_session_id` | A provider's context or resume token |

Harness IDs control resource lookup, cancellation, replay, and pruning.
A provider session ID is request data used to resume provider context. It
cannot look up a Harness resource.

## Runtime guarantees

- Resources survive the caller or stream consumer.
- Events have an increasing sequence within each resource.
- A terminal run, session, or accepted turn has one terminal event for its scope.
- An await timeout stops the caller's wait and leaves the work running.
- Process cancellation targets the managed process group.
- Output retention has memory and disk limits.
- Unknown options and unsupported values return errors.
- Built-in adapters launch an executable with separate arguments.

Resources are local to the current application instance. Harness does not
recover live work or reconstruct journals after a BEAM or host restart.

## Provider differences

The API uses common names and types. Optional behavior still depends on the
selected provider's ACP profile. Check its capabilities before requiring
resume, attachments, approvals, usage, or runtime model changes.

Input extensions belong under `provider_options`. Output that has no common
mapping uses `:provider_event`. See [Providers](providers.md) and
[Normalization and the data model](normalization_and_data_model.md).

## Package boundaries

Harness owns coding-agent execution, lifecycle, and retained results. ExMCP
owns ACP messages and protocol correlation. Jido Connect owns service API
integrations. The host application owns provider selection, workspace setup,
approval policy, retries, and durable job records.

Harness can run without `jido` or `jido_connect`. See the
[architecture reference](reference/architecture.md) for the process and
protocol boundary, and [dependencies](reference/dependencies.md) for release
audit exceptions.

## Start here

Follow [Getting started](getting_started.md) to install one provider and make
one request. Then read the guide for the API selected in the table above.
[Operations](operations.md) covers production limits, monitoring, and cleanup.

Three [Livebooks](livebooks/01_one_shot_requests.livemd) demonstrate blocking
runs, detached runs, and sessions with managed processes. Open them from a
source checkout. Provider cells use live CLIs and can consume paid usage.
