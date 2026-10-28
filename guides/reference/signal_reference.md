# Native Signal reference

Jido Harness V3 uses `Jido.Signal` for run, session, turn, provider, replay,
process, and command activity. There is no Harness event wrapper.

Every fact Signal uses a CloudEvents envelope. Its `data` map contains:

- the resource ID: `run_id`, `session_id`, or `process_id`;
- a resource-local, increasing `sequence`;
- a string-keyed `payload`;
- string-keyed `metadata`;
- provider, turn, request, and provider-session IDs when applicable.

Use `Jido.Harness.Signal.kind/1` for the short atom and
`Jido.Harness.Signal.sequence/1` for the cursor value.

## Run Signals

| Type | Kind |
| --- | --- |
| `jido.harness.run.started` | `:run_started` |
| `jido.harness.run.completed` | `:run_completed` |
| `jido.harness.run.failed` | `:run_failed` |
| `jido.harness.run.cancelled` | `:run_cancelled` |

A terminal run has exactly one terminal Signal.

## Session and turn Signals

| Type | Kind |
| --- | --- |
| `jido.harness.session.started` | `:session_started` |
| `jido.harness.session.ready` | `:session_ready` |
| `jido.harness.session.idle` | `:session_idle` |
| `jido.harness.session.closed` | `:session_closed` |
| `jido.harness.session.failed` | `:session_failed` |
| `jido.harness.session.cancelled` | `:session_cancelled` |
| `jido.harness.input.accepted` | `:input_accepted` |
| `jido.harness.turn.queued` | `:turn_queued` |
| `jido.harness.turn.started` | `:turn_started` |
| `jido.harness.turn.completed` | `:turn_completed` |
| `jido.harness.turn.failed` | `:turn_failed` |
| `jido.harness.turn.interrupted` | `:turn_interrupted` |
| `jido.harness.queue.changed` | `:queue_changed` |

Each accepted turn has exactly one terminal turn Signal.

## Output and interaction Signals

The normalized output kinds are `:output_text_delta`, `:output_text_final`,
`:structured_output`, `:thinking_delta`, `:command_output_delta`, `:tool_call`,
`:tool_result`, `:file_change`, `:plan_updated`, and `:usage`.

Approval exchange uses `:approval_requested` and `:approval_resolved`.
Provider data that has no common type uses `:provider_message`. Inspect its
`data["payload"]["kind"]` value before you use provider-specific data.

Raw ACP envelopes are private adapter data. Public Signals and replay records
do not expose them.

## Replay gaps

All resource types use `jido.harness.replay.gap` and the `:replay_gap` kind.
The payload has `from`, `to`, and `reason` string keys. The Signal sequence is
the end of the missing range.

```elixir
case Jido.Harness.Signal.kind(signal) do
  :replay_gap -> reset_projection(signal.data["payload"])
  _kind -> apply_signal(signal)
end
```

## Process Signals

Managed processes use these kinds:

- `:process_started`
- `:process_stdout`
- `:process_stderr`
- `:process_exited`
- `:process_failed`
- `:process_cancelled`
- `:process_timed_out`

For stdout and stderr, bytes are in `signal.data["payload"]["data"]`. Invalid
UTF-8 bytes use a map with `encoding: "base64"` and base64 `data`.

## Command Signals

The Plugin command types are under `jido.harness.command.*`. Typed Actions
validate these Signals and return plugin-owned Directives. Post-commit command
work returns `jido.harness.command.accepted` or
`jido.harness.command.failed` to the Agent.

Command IDs provide idempotency. A connection owns each run or session that it
starts. Another connection cannot control that resource.
