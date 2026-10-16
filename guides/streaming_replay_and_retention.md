# Streaming, replay, and retention

Runs, sessions, and processes expose the same observation pattern: ordered
events, cursor-based replay, and a pull-driven stream built on replay.

## Cursor semantics

Every event has an increasing `sequence` within its resource. A cursor means
"the last sequence already consumed."

```elixir
{:ok, events} = Jido.Harness.Run.replay(run_id, cursor: 20, limit: 100)
```

The returned page begins after sequence 20. Save the last returned sequence to
continue later. Cursors are resource-local and cannot be transferred between a
run, session, or process.

Replay defaults to a page size of 100 and caps a page at 10,000 events.

## Pull-based streams

```elixir
{:ok, stream} =
  Jido.Harness.Session.stream(session_id,
    cursor: saved_cursor,
    limit: 100,
    poll_interval_ms: 50
  )
```

The stream repeatedly requests bounded replay pages. When no page is available,
it checks resource state and polls again only while the resource is active. A
slow consumer therefore controls its own pace instead of accumulating an
unbounded mailbox.

Dropping a stream has no effect on the resource. A later process can attach
again from the last saved cursor.

## Memory tail and disk journal

The in-memory event and text tail is bounded. A segmented JSONL journal retains
older normalized records up to its disk limit.

Default limits are:

| Setting | Default |
| --- | --- |
| Memory tail | 1 MiB |
| Journal segment | 8 MiB |
| Total journal | 256 MiB |
| Terminal-resource TTL | 24 hours |

Retention maps accept:

- `journal_dir`
- `memory_bytes`
- `segment_bytes`
- `disk_limit_bytes`

Unknown keys and invalid byte relationships are rejected.

Each retained segment has a sparse sequence-to-byte index. Replay seeks to a
checkpoint near the requested cursor, then reads the requested page. Index
checkpoints are at most 64 records or about 64 KiB apart. One record can exceed
that byte interval. A poll at or past the latest sequence returns without file
access. Each request uses its own file handle, so readers can use independent
cursors and can seek backward.

Index entries are removed with their segments. If an existing journal is opened
again, its index is built once from the retained files. The journal still uses
the same redacted JSONL format.

## Replay gaps

When old journal segments have rotated away, replay cannot recreate every
sequence. The first returned record is then a replay-gap event identifying the
first still-available cursor.

Application consumers should treat a replay gap as a continuity boundary. Run
and session gaps use a `:provider_event` with `payload["kind"] ==
"replay_gap"`; process gaps use the `:replay_gap` process-event type:

```elixir
case event do
  %Jido.Harness.Event{type: :provider_event, payload: %{"kind" => "replay_gap"}} ->
    reset_projection(event)

  %Jido.Harness.ProcessEvent{type: :replay_gap} ->
    reset_projection(event)

  event ->
    apply_event(event)
end
```

Provider events use `Jido.Harness.Event`; process replay gaps use
`Jido.Harness.ProcessEvent`. Run and session replay gaps are represented as
normalized provider events with gap metadata.

## Text truncation

`RunResult` and `TurnResult` expose `text_truncated?`. When it is true:

- `text` contains the newest retained text tail;
- retained events remain available through replay;
- already-rotated journal segments cannot be reconstructed.

Use replay continuously when complete output is a hard requirement.

## Journal failure

If a journal cannot be created or written, the resource continues with bounded
memory and emits journal-error telemetry. Disk retention is operational support,
not a durable message broker.

A disk read error returns the available memory tail on the same replay call.
It does not disable future writes. Later replay calls retry the disk journal.
A cursor before the memory tail receives a replay-gap event. Healthy disk
replay always reads the redacted records from disk.

The internal ACP reader uses a separate demand-based memory stream. A read
waits for the next process event without polling or reading a journal. This
path preserves the original protocol bytes. Disk redaction must not change
messages sent to the ACP client. A slow internal reader that falls behind the
process memory buffer receives a gap, and the transport fails explicitly.
Public process replay continues to use the redacted journal.

## Pruning

Explicit `prune/1` removes a terminal resource and its journal. The retention
worker prunes terminal resources after their TTL. Active resources are never
removed by the TTL sweep.

## Security

Journal directories use restrictive permissions and structured secrets are
redacted before persistence. Journals still contain provider activity and
should be treated as sensitive operational data. Raw provider values are kept
out of disk records.
