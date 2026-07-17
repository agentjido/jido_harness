# Managed processes

`Jido.Harness.Process` supervises a local executable as an application-owned
resource. It is the public structured-process API and the execution foundation
used by built-in adapters.

## Start without a shell

```elixir
{:ok, process_id} =
  Jido.Harness.Process.start(%{
    executable: "git",
    argv: ["status", "--short"],
    cwd: File.cwd!(),
    stdin: false,
    runtime_timeout_ms: 30_000
  })
```

The executable and each argument are separate values. Jido.Harness never
constructs an interpolated shell command for a normal process spec.

## Process specification

A `Jido.Harness.ProcessSpec` supports:

- executable and argv;
- existing working directory;
- environment overlay or full replacement;
- stdin and optional PTY settings;
- startup, runtime, and idle timeouts;
- in-memory metadata;
- retention and journal limits.

Executables without a path separator are resolved through the runtime `PATH`.
Explicit paths are expanded and validated before launch.

## Send input

```elixir
:ok = Jido.Harness.Process.send_input(process_id, "one line\n")
:ok = Jido.Harness.Process.close_input(process_id)
```

Input is accepted only when stdin was enabled and the process remains active.

## Observe output

```elixir
{:ok, stream} = Jido.Harness.Process.stream(process_id)

Enum.each(stream, fn
  %Jido.Harness.ProcessEvent{type: :stdout, data: data} -> IO.write(data)
  %Jido.Harness.ProcessEvent{type: :stderr, data: data} -> IO.write(:stderr, data)
  event -> IO.inspect(event)
end)
```

Process events are ordered and cursor-addressable. Binary output is retained
without requiring it to be valid UTF-8.

## Await and inspect

```elixir
{:ok, %Jido.Harness.ProcessInfo{} = info} =
  Jido.Harness.Process.await(process_id, 30_000)

info.state
#=> :exited

info.exit_status
#=> 0
```

An await timeout stops waiting without terminating the process.

## Cancel or kill

```elixir
:ok = Jido.Harness.Process.cancel(process_id)
# or
:ok = Jido.Harness.Process.kill(process_id)
```

Graceful cancellation signals the complete process group and escalates from
SIGINT to SIGTERM to SIGKILL. `kill/1` skips directly to SIGKILL.

## Shell escape hatch

`Jido.Harness.Process.unsafe_shell_spec/2` exists for commands that genuinely
require shell parsing. Its name is deliberate. Built-in adapters never use it,
and applications should prefer an executable-plus-argv specification whenever
possible.

## Ownership and retention

Public managed processes survive caller and stream-consumer exits. They remain
addressable until explicitly pruned or removed by the terminal-resource TTL.
Provider-owned process workers additionally bind to their owning run or
transport so an abnormal owner failure cleans up the CLI process group.

See the exact [process management reference](../docs/process_management.md) and
[Streaming, replay, and retention](streaming_replay_and_retention.md).
