# Runs

A run sends one finite provider request through ACP and produces one terminal
`Jido.Harness.RunResult`. Use the blocking API to wait in the caller, or the
detached API to receive a `run_id` before completion. Both use the same
supervised lifecycle.

## Wait for one run

```elixir
{:ok, result} =
  Jido.Harness.run(:codex, "Explain this repository",
    cwd: File.cwd!(),
    runtime_timeout_ms: 300_000,
    await_timeout: 320_000
  )
```

Accepted requests are a prompt string, a map or keyword list of normalized
fields, or a `Jido.Harness.RunRequest`. Select the provider explicitly, include
it in the request, or configure `:default_provider`.

`await_timeout` limits the caller's wait. `runtime_timeout_ms` limits the work.
An expired await returns `{:error, :timeout}` and leaves the run active. Use
the detached API when you need its ID before waiting.

## Start a detached run

```elixir
{:ok, run_id} =
  Jido.Harness.Run.start(:codex, %{
    prompt: "Review the current branch",
    cwd: File.cwd!(),
    sandbox_mode: :read_only,
    runtime_timeout_ms: 300_000,
    idle_timeout_ms: 120_000,
    metadata: %{request_origin: "review-button"}
  })
```

Starting returns after validation and worker creation. Provider initialization
and execution continue asynchronously. The run belongs to the application,
not to the caller.

The selected `ACPAgentSpec` must support each non-default request option.
The schema includes model, provider resume ID, environment, attachments, MCP
configuration, sandbox settings, and other normalized fields. A schema field
alone does not establish provider support. See [Providers](providers.md).

One run sends one ACP turn. `max_turns` is rejected. No built-in profile
supports `structured_output`. Finite runs also reject `approval_mode: :prompt`:
they approve permission requests in `:auto_approve` mode and deny them in
other modes. Use the [approval-policy recipe](recipes/policy_jobs.md) when
host code must decide each permission request.

## Inspect and list

```elixir
{:ok, info} = Jido.Harness.Run.info(run_id)

Jido.Harness.Run.list(
  providers: [:codex],
  states: [:starting, :running]
)
```

`RunInfo` contains lifecycle state, timestamps, provider resume ID, output
cursor, metadata, journal location, and any terminal error. Keep the run ID
when another process must inspect or control the work.

## Stream and replay

```elixir
{:ok, stream} =
  Jido.Harness.Run.stream(run_id, cursor: 0, limit: 100, poll_interval_ms: 25)

Enum.each(stream, fn event ->
  IO.inspect({event.sequence, event.type})
end)
```

The stream pulls bounded replay pages until the run becomes terminal.
Dropping the stream does not cancel the run.

For explicit pages:

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

A cursor is the last consumed sequence. Replay returns later events and caps
each page at 10,000. See [Streaming, replay, and retention](streaming_replay_and_retention.md)
for journal limits and replay gaps.

## Await and handle the result

```elixir
case Jido.Harness.Run.await(run_id, 320_000) do
  {:ok, %Jido.Harness.RunResult{status: :completed} = result} ->
    {:ok, result.text}

  {:ok, %Jido.Harness.RunResult{} = result} ->
    {:error, result.error || result.status}

  {:error, :timeout} ->
    {:pending, run_id}

  {:error, reason} ->
    {:error, reason}
end
```

A returned result is terminal. Its status is `:completed`, `:failed`, or
`:cancelled`. The outer `{:ok, result}` tuple does not establish task success.

`text` is the bounded final text tail. `usage` contains the data the provider
supplies, and `events` contains the retained memory tail. If
`text_truncated?` is true, use replay for the complete retained sequence.
Rotated journal segments cannot be recovered.

## Resume provider context

When the profile supports session loading, pass a previous result's
`provider_session_id` in a new request:

```elixir
Jido.Harness.run(:codex, %{
  prompt: "Continue with the next step",
  cwd: File.cwd!(),
  provider_session_id: prior_result.provider_session_id,
  runtime_timeout_ms: 300_000
})
```

This creates a new Harness run. For one conversation that stays open across
turns, use [Interactive sessions](interactive_sessions.md).

## Cancel and prune

```elixir
:ok = Jido.Harness.Run.cancel(run_id)
{:ok, result} = Jido.Harness.Run.await(run_id, 30_000)
:ok = Jido.Harness.Run.prune(run_id)
```

Cancellation stops the provider execution and its managed process group.
Pruning removes a terminal worker and its journal. A terminal run cannot be
restarted. Start a new run or resume provider context with a new request.

Terminal resources are also pruned after the configured TTL, which defaults
to 24 hours. See [Ownership, timeouts, and cancellation](ownership_timeouts_and_cancellation.md).
