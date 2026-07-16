# Process management

`Jido.Harness.ProcessManager` owns direct CLI processes independently of their
callers. Each process gets a stable `process_id`; provider runs have a separate
stable `run_id`; provider session IDs are used only for resume semantics.

## Process specification

A process spec uses `executable` plus `argv` and supports:

- existing local `cwd`;
- environment overlay or replacement;
- stdin and optional PTY;
- startup, runtime, and idle timeouts;
- in-memory metadata;
- retention and journal limits.

Built-in adapters never use the explicitly named `unsafe_shell_spec/2` helper.

## Ownership and shutdown

Managed workers are temporary and never restart a finished or crashed command.
They survive caller and stream-consumer exits. On application shutdown every
managed process group is sent SIGKILL.

Direct CLI adapters additionally bind their process worker to the owning run
worker. An abnormal run-worker exit therefore cancels the CLI process group,
while ordinary public processes remain caller-independent.

Cancellation sends SIGINT to the process group, waits five seconds, sends
SIGTERM, waits five seconds, and finally sends SIGKILL. `kill_process/1` skips
directly to SIGKILL.

## Output retention

The default memory tail is 1 MiB. The default segmented JSONL journal is 256 MiB
under `:filename.basedir(:user_cache, "jido_harness")`. Harness directories are
mode `0700` and journal files are mode `0600`.

Old segments rotate out at the disk limit. Replay from an unavailable cursor
begins with a `:replay_gap` event. If journal creation or writes fail, the
process continues with bounded memory and emits journal error telemetry.

Environment values and full process specifications are never journaled.

## Streaming

`stream_process/2` and run `stream/2` are pull-based cursor streams. A slow
consumer polls retained events and does not receive an unbounded producer
mailbox. `replay_process/2` and `replay/2` accept `:cursor` and `:limit`.

Completed processes and runs remain addressable for 24 hours by default, then
the retention worker prunes them.
