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
    session_idle_timeout_ms: 1_800_000
  })
```

The returned harness `session_id` controls this resource. The separate
`provider_session_id`, when available, is the provider's context or resume
token.

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

Follow-ups are processed FIFO. A transport may provide native multi-turn
context or the harness may manage it by resuming the provider between turns.
Inspect `SessionInfo.transport` and the provider's `SessionTransportSpec` when
the distinction matters.

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
transport supports it. The turn receives one `:turn_interrupted` terminal
event.

## Steering, approvals, and configuration

These operations are capability-dependent:

```elixir
Jido.Harness.Session.steer(session_id, "Focus only on the failing test")
Jido.Harness.Session.respond_approval(session_id, request_id, :approve)
Jido.Harness.Session.configure(session_id, %{model: "new-model"})
```

Unsupported interactions return a normalized capability error before provider
dispatch. Do not infer native support from the existence of a public function.
The selected transport's `InteractionCapabilities` is authoritative.

## Close, kill, and prune

```elixir
:ok = Jido.Harness.Session.close(session_id)
:ok = Jido.Harness.Session.prune(session_id)
```

`close/1` is graceful: it resolves pending approvals as denied, stops the
transport, and emits one terminal session event. `kill/1` forcibly cancels the
session. Only terminal sessions can be pruned.

## Timeouts

Session requests distinguish:

- runtime and idle timeouts for each active turn;
- an idle timeout for the session between turns;
- an approval-response timeout;
- the caller's independent `Jido.Harness.Session.await/3` timeout.

An await timeout never interrupts the turn. Read
[Ownership, timeouts, and cancellation](ownership_timeouts_and_cancellation.md)
for the complete model.
