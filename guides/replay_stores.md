# Replay stores

`Jido.Harness.ReplayStore` separates retained replay from execution and provider
protocols. The default remains `Jido.Harness.ReplayStore.File`, which wraps the
segmented file journal. No database or cloud dependency is required.

## Select a store

```elixir
config :jido_harness,
  replay_store: {Jido.Harness.ReplayStore.File, %{
    journal_dir: "/var/lib/my_app/harness",
    segment_bytes: 8_388_608,
    disk_limit_bytes: 268_435_456,
    max_events: 1_000_000
  }}
```

The module and options are validated before provider execution starts. File
options override process-manager defaults; explicit resource retention overrides
file options. Adapter selection is application-wide. Per-resource adapter
selection is not part of this interface.

Two memory stores are also available:

```elixir
config :jido_harness,
  replay_store: {Jido.Harness.ReplayStore.ETS, %{max_bytes: 1_048_576, max_events: 10_000}}
```

`ReplayStore.Memory` uses an ordered tree in worker state. `ReplayStore.ETS`
uses one private ordered-set table per resource, owned by the resource worker.
Both use the same limits and indexed reads. Neither starts another process.
Records remain after a caller exits and after execution completes, while the
resource worker remains alive. Worker exit or application restart removes
memory records. Persistent files do not restore provider execution.

## Page and gap contract

Process, run, and session APIs expose `replay_page/2`:

```elixir
{:ok, page} = Jido.Harness.Run.replay_page(run_id,
  cursor: saved_cursor,
  limit: 100,
  max_bytes: 1_048_576
)

Enum.each(page.records, &apply_event/1)
Enum.each(page.gaps, &report_missing_range/1)
saved_cursor = page.next_cursor
```

`page.records` contains the API's event structs. Storage callbacks use prepared
maps with string keys. Page fields are:

| Field | Meaning |
| --- | --- |
| `records` | Events after the exclusive input cursor, in sequence order |
| `gaps` | Inclusive missing ranges: `%{from: first, to: last, reason: reason}` |
| `next_cursor` | Last sequence covered by records or reported gaps |
| `oldest_sequence` | First retained sequence, or `nil` if none remain |
| `latest_sequence` | Latest sequence known to the store handle, including rejected records |
| `bytes` | JSON bytes in returned records, without line separators |

For records 1, 4, and 6, a read after 0 with a count limit of 2 returns records
1 and 4, gap 2–3, and next cursor 4. It reports gap 5 on the next page. Missing
ranges do not consume sequence numbers and do not become stored events.

`:unavailable` covers retention, rejected appends, and unavailable storage.
It does not claim a more precise cause. `:page_limit` means one retained record
is larger than the read byte limit. The page skips that record and advances its
cursor. A read with a larger limit can still retrieve that retained record.
A record that fits a full page but cannot fit the remaining bytes waits for the
next page. The count limit also bounds inspected oversized records, so gaps
cannot cause an unbounded read.

An empty retained store can report a gap and advance to its latest known
sequence. Reads at the latest sequence return no records or gaps without a
history scan. A cursor beyond the latest sequence never moves backwards.

Defaults are 100 inspected records and 1 MiB per read; count is capped at
10,000. Metadata is outside the byte budget. Existing `replay/2` and `stream/2`
return ordered event lists with gap events at each missing range. Gap metadata
includes `from_sequence`, `to_sequence`, `reason`, and the compatible
`available_from` field.

## Data and failure policy

The core assigns sequences, removes raw payloads, removes known secrets, and
prepares a format-version-1 record before calling storage. File, memory, ETS,
and fallback all receive the same prepared record. Adapters do not receive the
request, environment, or secret list. Public retained replay always follows this
policy. Live internal ACP delivery preserves original protocol bytes through a
separate bounded buffer. Result text and result objects keep their existing
policy; this change does not redact them.

Each resource also keeps a sanitized fallback tree, bounded by `memory_bytes`
(default 1 MiB) and 10,000 records. This is separate from the original live event
buffer and the selected store. Include all of them when sizing memory. Selecting
a memory adapter does not remove the fallback budget.

A failed open or append keeps execution active and uses fallback for the rest
of that resource's lifetime. Later appends still attempt the selected store.
A read failure uses fallback on the same call and retries the selected store on
the next read. Missing fallback history is reported as gaps, including the known
sequence range after a persistent store is reopened. Callback exceptions,
invalid responses, and invalid page ranges become storage failures.
Synchronous callbacks must finish promptly: the core
cannot interrupt a blocking callback. A remote adapter must isolate I/O and use
bounded queues and deadlines.

Resource info includes storage-neutral `replay_store` metadata with adapter,
status, sequence boundaries, retained bytes, and retained count. `journal_dir`
remains available for file storage and is `nil` for memory stores. After an open
or append failure, retained counts describe the fallback. A read failure can
also use this smaller fallback. Store telemetry never includes record content
or secrets.

## Retention and cleanup

Memory byte limits count JSON record bytes. File limits count JSONL bytes,
including line separators, and remove complete segments. A record larger than
the store budget is rejected from retention; sequence progress remains valid.
The file adapter keeps a small cursor file when no record can preserve that
progress. Metadata files are outside the JSONL budget. No fsync guarantee is
made. File page reads stop at the byte budget with one record of lookahead;
oversized payloads are discarded after their sequence and size are read.
Reopen starts a new segment after a nonempty file, so a truncated tail cannot
absorb the next write. Retrying an identical retained record succeeds; different data at that
sequence returns `:sequence_conflict`. An expired sequence returns
`:expired_sequence`, because its original data is no longer available to compare.

Close releases handles without deleting records. Explicit prune and terminal
TTL expiry request deletion. A deletion failure is returned; the worker remains
available for retry. A store handle must be discarded after successful delete.
Deleting the same handle again is safe. Deleting an immutable memory handle
means discarding that state; it cannot revoke copies retained by its caller.

Per-resource budgets do not cap total application memory. Use resource limits
at the application boundary. Durable audit policy, access control, execution
retries, historical lookup without a live worker, and execution recovery remain
application responsibilities.

## Extend and measure

Implement all callbacks in `Jido.Harness.ReplayStore`. Treat state as opaque.
Resource identity includes kind, ID, and record format version. Append success
makes a retained record visible to the next read; it does not promise crash
survival or remote replication. An adapter must release resources after partial
initialization failure.

The same contract suite runs against all built-in stores. It checks cursors,
internal gaps, empty histories, count and byte budgets, duplicate writes,
conflicts, expiry, close, and repeated delete. Separate tests check fallback,
redaction, owner exit, and public APIs.

Run `mix run bench/replay_store.exs` to compare the original queue buffer,
worker-owned indexed memory, and ETS without provider tools. See
[Testing](testing.md#replay-store-measurements) and the recorded
[benchmark results](replay_store_benchmarks.md).
