# Managed processes

`Jido.Harness.Process` supervises a local executable as an application-owned
resource. Use it for programs that do not need a provider run. Each process
has a stable `process_id` and separate `ProcessEvent` records.

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

The executable and arguments are separate values. Built-in adapters also use
this process API. They never interpolate a shell command.

## Process specification

`Jido.Harness.ProcessSpec` accepts:

| Field | Default | Contract |
| --- | --- | --- |
| `executable` | required | Command name or explicit path |
| `argv` | `[]` | List of binary arguments |
| `cwd` | current directory | Non-empty path without null bytes |
| `env` | `%{}` | String keys and string, `false`, or `nil` values |
| `env_mode` | `:overlay` | `:overlay` or `:replace` |
| `stdin` | `true` | Whether input is available |
| `pty` | `false` | Boolean or PTY keyword options |
| `startup_timeout_ms` | `15_000` | Positive integer |
| `runtime_timeout_ms` | `:infinity` | Positive integer or `:infinity` |
| `idle_timeout_ms` | `:infinity` | Positive integer or `:infinity` |
| `metadata` | `%{}` | In-memory application metadata |
| `retention` | `%{}` | Memory and journal overrides |

Unknown fields are rejected. The local Erlexec driver resolves command names
through the runtime `PATH`. It expands and checks explicit paths.

Request constructors validate the working-directory path without checking
the caller's filesystem. The driver checks the directory on the execution
host. Erlexec reports `:failed` with a validation error for a missing local
directory. A custom remote driver can accept a directory that exists only on
its host. This does not make attachment reads, provider installation, or
readiness checks remote.

## Environment

`:overlay` inherits the BEAM environment and applies supplied values.
`:replace` starts with only the supplied environment. A `false` or `nil`
value removes a variable. Replacement mode requires the application to supply
the values the program needs.

Environment values and complete process specifications are not journaled.
See [Security](security.md) for the limits of environment isolation and
redaction.

## Send input

```elixir
:ok = Jido.Harness.Process.send_input(process_id, "one line\n")
:ok = Jido.Harness.Process.close_input(process_id)
```

Use these calls on a process started with `stdin: true`. Input is accepted
while the process is active. Closing input sends EOF; PTY input uses the
terminal end-of-transmission character.

## Observe output

```elixir
{:ok, stream} = Jido.Harness.Process.stream(process_id)

Enum.each(stream, fn
  %Jido.Harness.ProcessEvent{type: :stdout, data: data} -> IO.write(data)
  %Jido.Harness.ProcessEvent{type: :stderr, data: data} -> IO.write(:stderr, data)
  event -> IO.inspect(event)
end)
```

Event types are `:started`, `:stdout`, `:stderr`, `:exited`, `:failed`,
`:cancelled`, `:timed_out`, and `:replay_gap`. Output remains binary and
need not be valid UTF-8.

Streams and replay use resource-local sequence cursors. Pages are capped at
10,000 events. After exit, the manager waits for a 50-millisecond output quiet
period before it appends the terminal event. Each trailing output event resets
that period. A deadline of four times the configured period bounds the drain.

## Await and inspect

```elixir
{:ok, info} = Jido.Harness.Process.await(process_id, 30_000)
{info.state, info.exit_status}
```

`await/2` returns terminal process information. An await timeout returns
`{:error, :timeout}` and leaves the process active. Check both state and exit
status: a returned info struct does not establish successful execution.

Use `Jido.Harness.Process.info/1` for a snapshot and
`Jido.Harness.Process.list/1` for lifecycle inspection.

## Cancel or kill

```elixir
:ok = Jido.Harness.Process.cancel(process_id)
```

Graceful cancellation targets the complete process group:

1. send SIGINT;
2. wait `cancel_grace_ms`, five seconds by default;
3. send SIGTERM;
4. wait `term_grace_ms`, five seconds by default;
5. send SIGKILL.

`Jido.Harness.Process.kill/1` sends SIGKILL immediately. These grace periods
are configured under `:process_manager`; see the
[configuration reference](reference/configuration_reference.md).

## Ownership and retention

Public processes survive caller and stream-consumer exits. Provider processes
also monitor their run or session owner; abnormal owner failure cancels their
CLI process group. Application shutdown ends managed processes.

Prune a terminal process when its history is no longer needed:

```elixir
:ok = Jido.Harness.Process.prune(process_id)
```

The default memory tail is 1 MiB. Journals use 8 MiB segments, a 256 MiB disk
limit per resource, and a private user-cache directory. Journal failure leaves
bounded memory retention and emits telemetry. Full cursor and retention rules
are in [Streaming, replay, and retention](streaming_replay_and_retention.md).

## Shell escape hatch

`Jido.Harness.Process.unsafe_shell_spec/2` builds a shell-backed specification.
Use it only when shell parsing is required and interpolated input is trusted.
Built-in adapters do not call it.
