# Ownership, timeouts, and cancellation

Jido.Harness separates resource ownership, caller waiting, provider execution,
and cancellation. Understanding those boundaries prevents accidental orphaning
or premature termination.

## Application ownership

Public runs, sessions, and processes are supervised by the Jido.Harness
application. They do not link their lifetime to the process that called
`start`, `stream`, or `await`.

This supports workflows such as:

- return a run ID from an HTTP request;
- stream progress from a LiveView process;
- reconnect after that consumer exits;
- await or cancel from a later process.

Application shutdown is the ownership boundary. Resources are not rebuilt on a
new BEAM instance.

## Provider-owned processes

The OS process beneath an adapter is owned by its run or session transport.
Abnormal owner termination therefore cancels the complete CLI process group.
This is different from a public `Jido.Harness.Process`, which remains
caller-independent until explicitly stopped or pruned.

## Timeout vocabulary

| Timeout | Controls | Cancels work when reached? |
| --- | --- | --- |
| `await_timeout` | `Jido.Harness.run` caller | no |
| `Jido.Harness.Run.await/2` timeout | detached run waiter | no |
| `Jido.Harness.Session.await/3` timeout | turn waiter | no |
| `Jido.Harness.Process.await/2` timeout | process waiter | no |
| `runtime_timeout_ms` | total run/process execution | yes |
| `idle_timeout_ms` | run/process inactivity | yes |
| `turn_runtime_timeout_ms` | active session turn | yes |
| `turn_idle_timeout_ms` | inactive session turn | yes |
| `session_idle_timeout_ms` | idle time between turns | closes session |
| `approval_timeout_ms` | unresolved approval | resolves through session lifecycle |

Timeout fields default to `:infinity` unless a caller or provider default sets
them. Production applications should choose finite values based on the work.

## Run cancellation

```elixir
:ok = Jido.Harness.Run.cancel(run_id)
```

The run reaches `:cancelled` and emits exactly one `:run_cancelled` event.
Cancellation does not delete the resource; its result and journal remain
available until pruning.

## Turn interruption

```elixir
:ok = Jido.Harness.Session.interrupt(session_id, :active)
```

Interrupt ends one active turn and preserves the session when supported. The
turn receives `:turn_interrupted`; the session can accept later input.

## Session close and kill

`Jido.Harness.Session.close/1` is graceful and produces a closed lifecycle.
`Jido.Harness.Session.kill/1`
forcibly cancels the session and transport. Both leave a terminal resource that
can be replayed and pruned.

## Process cancellation escalation

`Jido.Harness.Process.cancel/1` signals the entire process group with SIGINT, waits five
seconds, sends SIGTERM, waits five more seconds, then sends SIGKILL.
`Jido.Harness.Process.kill/1` immediately sends SIGKILL to the group.

Group-level signaling matters for coding-agent CLIs because they may create
tool subprocesses. Killing only the CLI parent can leave those children alive.

## Automatic retention cleanup

Terminal resources remain addressable for 24 hours by default. The retention
worker periodically prunes expired runs, sessions, and processes. Configure the
TTL and sweep interval under `:process_manager`; see the
[configuration reference](../docs/configuration_reference.md).
