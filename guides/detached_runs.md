# Detached runs

`Jido.Harness.Run` exposes the complete lifecycle of one finite provider
execution. The run is supervised independently of the caller and identified by
a stable `run_id`.

## Start

```elixir
{:ok, run_id} =
  Jido.Harness.Run.start(:codex, %{
    prompt: "Review the current branch",
    cwd: File.cwd!(),
    sandbox_mode: :read_only,
    runtime_timeout_ms: 600_000
  })
```

Starting returns after request validation and worker creation. Provider output
arrives asynchronously.

## Inspect and list

```elixir
{:ok, %Jido.Harness.RunInfo{} = info} = Jido.Harness.Run.info(run_id)

running_codex =
  Jido.Harness.Run.list(
    providers: [:codex],
    states: [:starting, :running]
  )
```

`RunInfo` is a redacted snapshot containing lifecycle state, timestamps,
provider resume ID, output cursor, metadata, journal location, and terminal
error when present.

## Attach to the event stream

```elixir
{:ok, stream} =
  Jido.Harness.Run.stream(run_id,
    cursor: 0,
    limit: 100,
    poll_interval_ms: 25
  )

Enum.each(stream, fn event ->
  IO.inspect({event.sequence, event.type})
end)
```

The stream pulls replay pages and polls only while the run is non-terminal. It
does not subscribe the consumer process to an unbounded producer mailbox.
Starting from a saved cursor reattaches without repeating older events.

## Replay explicit pages

```elixir
{:ok, first_page} = Jido.Harness.Run.replay(run_id, cursor: 0, limit: 100)

next_cursor =
  case List.last(first_page) do
    nil -> 0
    event -> event.sequence
  end

{:ok, second_page} =
  Jido.Harness.Run.replay(run_id, cursor: next_cursor, limit: 100)
```

Replay returns events whose sequence is greater than the supplied cursor. The
maximum page size is 10,000.

## Await

```elixir
{:ok, %Jido.Harness.RunResult{} = result} =
  Jido.Harness.Run.await(run_id, 600_000)
```

An await timeout does not cancel the run. Any process with the ID can await it
later.

## Cancel

```elixir
:ok = Jido.Harness.Run.cancel(run_id)
```

Cancellation requests termination of the provider execution and its complete
managed process group. A terminal run cannot be restarted; start a new run or
resume provider context with a new request.

## Prune

```elixir
:ok = Jido.Harness.Run.prune(run_id)
```

Pruning removes a terminal worker and its journal immediately. Terminal
resources are also pruned automatically after the configured TTL, which is 24
hours by default.

## Caller independence

The caller that starts, streams, or awaits a run is not its lifecycle owner. A
web request process can return the ID, a LiveView can stream progress, and a
later process can replay or await the same run. The application supervision
tree remains the owner until the run is pruned or the application stops.

Read [Streaming, replay, and retention](streaming_replay_and_retention.md) for
cursor and journal semantics.
