# Process management reference

`Jido.Harness.Process` owns structured OS processes independently of their
callers. Each process receives a stable `process_id`; provider runs and sessions
keep their own distinct harness IDs.

## Process specification

`Jido.Harness.ProcessSpec` accepts:

| Field | Default | Contract |
| --- | --- | --- |
| `executable` | required | command name or explicit path |
| `argv` | `[]` | list of binary arguments |
| `cwd` | current directory | existing directory |
| `env` | `%{}` | string keys and string, `false`, or `nil` values |
| `env_mode` | `:overlay` | `:overlay` or `:replace` |
| `stdin` | `true` | whether input is available |
| `pty` | `false` | boolean or PTY keyword options |
| `startup_timeout_ms` | `15_000` | positive integer |
| `runtime_timeout_ms` | `:infinity` | positive integer or `:infinity` |
| `idle_timeout_ms` | `:infinity` | positive integer or `:infinity` |
| `metadata` | `%{}` | in-memory application metadata |
| `retention` | `%{}` | memory and journal overrides |

Unknown fields are rejected. An executable without a path separator is
resolved through `PATH`; an explicit path is expanded and checked directly.

## Environment behavior

`:overlay` inherits the BEAM environment and applies supplied values. `:replace`
starts from only the supplied environment. A `false` or `nil` value removes the
variable.

Environment values and complete process specifications are not written to the
journal.

## Ownership

Public process workers use temporary restart semantics and survive caller or
stream-consumer exits. They terminate on application shutdown.

Adapter-owned processes additionally monitor their run or transport owner. An
abnormal owner exit cancels the CLI process group so tool children are not left
behind.

## Input

`Jido.Harness.Process.send_input/2` writes binary data while the process is
running. `Jido.Harness.Process.close_input/1` sends EOF. PTY-backed EOF is translated to the terminal
end-of-transmission character.

## Cancellation

Graceful cancellation targets the complete process group:

1. send SIGINT;
2. wait `cancel_grace_ms`, five seconds by default;
3. send SIGTERM;
4. wait `term_grace_ms`, five seconds by default;
5. send SIGKILL.

`Jido.Harness.Process.kill/1` sends SIGKILL immediately.

## Process events

`Jido.Harness.ProcessEvent` types are `:started`, `:stdout`, `:stderr`,
`:exited`, `:failed`, `:cancelled`, `:timed_out`, and `:replay_gap`.

stdout and stderr data remain binary. Replay pages are cursor-addressed and
capped at 10,000 events.

## Retention

The default in-memory tail is 1 MiB. The default segmented journal uses 8 MiB
segments with a 256 MiB per-resource disk limit under
`:filename.basedir(:user_cache, "jido_harness")`.

Directories use mode `0700`; journal files use mode `0600`. Old segments rotate
out at the disk limit. Replay from an unavailable cursor begins with a
`:replay_gap` event.

If journal creation or writing fails, the process continues with bounded memory
and emits journal-error telemetry.

## Shell-backed processes

`Jido.Harness.Process.unsafe_shell_spec/2` builds an explicitly shell-backed process spec.
Built-in adapters never call it. Prefer executable-plus-argv execution to avoid
shell injection and quoting ambiguity.
