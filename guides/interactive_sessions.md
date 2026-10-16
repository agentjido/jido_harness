# Interactive sessions

`Jido.Harness.Session` owns a multi-turn provider conversation independently of
the processes that submit or consume turns.

## Start a session

```elixir
{:ok, session_id} =
  Jido.Harness.Session.start(:codex, %{
    cwd: File.cwd!(),
    sandbox_mode: :workspace_write,
    turn_runtime_timeout_ms: 600_000,
    approval_timeout_ms: 30_000,
    session_idle_timeout_ms: 1_800_000
  })

{:ok, %Jido.Harness.SessionInfo{state: :idle}} =
  Jido.Harness.Session.info(session_id)
```

The returned harness `session_id` controls this resource. The separate
`provider_session_id`, when available, is the provider's context or resume
token.

Starting returns a worker ID before ACP initialization finishes. The info
call can wait for startup and confirms the idle state before input. A startup
failure leaves a terminal session with its error and retained events.

## Resume or fork a provider conversation

A session request with `provider_session_id` loads that provider
conversation (ACP `session/load`) and continues it. A request with
`fork_session_id` opens a new, independent conversation that starts as a copy
of that one (ACP `session/fork`):

```elixir
{:ok, side_id} =
  Jido.Harness.Session.start(:claude, %{
    cwd: File.cwd!(),
    fork_session_id: info.provider_session_id
  })
```

The original conversation is untouched, so the copy can answer a side
question or try an alternative without disturbing it. `session/fork` is still
unstable in ACP: the ACP client refuses an agent that does not advertise
`sessionCapabilities.fork`. A request cannot give both `provider_session_id`
and `fork_session_id`.

## Send an idle turn

```elixir
{:ok, turn_id} =
  Jido.Harness.Session.send_message(
    session_id,
    "Summarize the architecture"
  )

{:ok, %Jido.Harness.TurnResult{} = turn} =
  Jido.Harness.Session.await(session_id, turn_id, 600_000)
```

`send_message/3` requires an idle session. The accepted `turn_id` remains
stable across event streaming and later lookup.

## Queue follow-up turns

```elixir
{:ok, risks_id} =
  Jido.Harness.Session.follow_up(
    session_id,
    "Identify the main operational risks"
  )

{:ok, tests_id} =
  Jido.Harness.Session.follow_up(
    session_id,
    "Then suggest one test for each risk"
  )
```

Follow-ups are processed FIFO through the same ACP session. A full queue returns
`{:error, :queue_full}` before it accepts a turn. Session requests can set these
harness limits. Each value must be a positive integer.

| Option | Default | Meaning |
| --- | --- | --- |
| `max_queued_turns` | 128 | Maximum waiting turns, excluding the active turn |
| `max_queued_bytes` | 4 MiB | Maximum external-term bytes of queued turn requests |
| `max_retained_turns` | 100 | Maximum completed turn results held in memory |
| `max_result_bytes` | 4 MiB | Maximum external-term bytes of completed results |
| `max_pending_approvals` | 128 | Maximum pending approval requests |

The oldest completed results expire when either result limit is reached.
Later `turn_result/2` and `await/3` calls return `{:error, :not_found}` for an
expired turn. Callers already waiting for that turn receive its result. A
single result larger than `max_result_bytes` is delivered to current waiters
and is then discarded. Journal event retention is separate from result
retention. Store results in the host application if you need a longer history.
Approval requests above the limit are denied, and the session records an
`approval_limit_reached` provider event.

## Inspect, stream, and replay

```elixir
{:ok, %Jido.Harness.SessionInfo{} = info} =
  Jido.Harness.Session.info(session_id)

{:ok, stream} = Jido.Harness.Session.stream(session_id, cursor: 0)

Enum.each(stream, fn event ->
  IO.inspect({event.sequence, event.turn_id, event.type})
end)
```

Session streams include session lifecycle, queue, approval, turn, provider,
and output events in one ordered sequence.

## Interrupt an active turn

```elixir
:ok = Jido.Harness.Session.interrupt(session_id, :active)
```

Interrupt ends the active turn while preserving a healthy session when the
ACP agent supports it. The turn receives one `:turn_interrupted` terminal
event.

## Steering, approvals, and configuration

Approval responses and configuration changes depend on the selected profile:

```elixir
Jido.Harness.Session.respond_approval(session_id, request_id, :approve)
Jido.Harness.Session.configure(session_id, %{model: "new-model"})
```

Unsupported interactions return a normalized capability error before provider
dispatch. Do not infer native support from the existence of a public function.
The selected `ACPAgentSpec.capabilities` value is authoritative.

### Steer an active turn

`steer/3` adds input to the turn that is running instead of queueing a new
turn behind it:

```elixir
input = "Use the staging database instead"

case Jido.Harness.Session.steer(session_id, input) do
  {:ok, turn_id} ->
    {:joined, turn_id}

  # nothing was sent: the turn had already ended, or the agent cannot steer
  {:error, :no_active_turn} ->
    Jido.Harness.Session.follow_up(session_id, input)

  {:error, %Jido.Harness.Error{details: %{capability: :steer}}} ->
    Jido.Harness.Session.follow_up(session_id, input)
end
```

It works for an ACP agent that advertises steering in its `initialize`
response (`_meta.steering.supported`), such as claude-agent-acp 0.70 and
codex-acp 1.6.2. The harness sends the extension request `_session/steering`
and returns the id of the turn the input joined. That turn still ends once,
after the agent has read the input.

The request never starts a turn of its own (`idleBehavior:
"promptRequired"`): when the turn has just ended, `steer/3` returns
`{:error, :no_active_turn}` and nothing was sent, so the caller can queue the
input with `follow_up/3`. For an agent without steering, `steer/3` returns the
normalized capability error; queue the input, or interrupt the active turn and
send it as a new message.

If an agent ignores `promptRequired` and reports `startedNewTurn`, the
harness returns `{:error, {:steering_failed, :unexpected_new_turn}}`, fails
the session, and stops the provider process. The new turn has no harness
turn ID. Do not retry the input automatically: the agent may have acted on it.

If the agent does not answer within 10 seconds, `steer/3` returns
`{:error, {:steering_failed, :timeout}}`. The harness also fails the session
and stops the provider because the input's outcome is unknown. Do not retry
the input automatically after this error.

Steering uses the same `:acp_max_frame_bytes` limit as normal prompts. An
encoded request over the limit returns
`{:error, {:steering_failed, :frame_too_large}}` before anything is sent.
The current turn remains usable. Unsupported optional steering metadata is
ignored; only `_meta.steering.supported: true` enables steering.

### Approvals between turns

Some agents ask permission outside a turn: a tool started in the background
can need approval after the turn that started it has ended. While the session
is idle, such a request (one without a turn id) is emitted as
`:approval_requested` and answered with `respond_approval/3` like any other.
Once it is answered or times out, the session is idle again and starts any
queued follow-up. A request naming a turn that has already ended is still
denied.

For application approval rules, see the tested
[policy job recipe](recipes/policy_jobs.md). Set a finite approval timeout so
an unanswered permission request cannot wait without a limit.

## Close, kill, and prune

```elixir
:ok = Jido.Harness.Session.close(session_id)
:ok = Jido.Harness.Session.prune(session_id)
```

`close/1` is graceful: it resolves pending approvals as denied, stops the
ACP process, and emits one terminal session event. `kill/1` forcibly cancels the
session. Only terminal sessions can be pruned.

## Timeouts

Session requests distinguish:

- runtime and idle timeouts for each active turn;
- an idle timeout for the session between turns;
- an approval-response timeout;
- the caller's independent `Jido.Harness.Session.await/3` timeout.

Turn statuses are `:completed`, `:failed`, and `:interrupted`. Check status
even when await returns `{:ok, turn}`.

An await timeout never interrupts the turn. Read
[Ownership, timeouts, and cancellation](ownership_timeouts_and_cancellation.md)
for the complete model.
