# Streaming, replay, and retention

Runs, sessions, and processes expose ordered native Signals, cursor replay,
and pull streams.

## Cursors and pages

Each Signal has an increasing resource-local sequence. A cursor is the last
sequence that the consumer accepted.

```elixir
{:ok, signals} = Jido.Harness.Run.replay(run_id, cursor: 20, limit: 100)
cursor = signals |> List.last() |> Jido.Harness.Signal.sequence()
```

Replay begins after the cursor. `replay_page/2` also returns `next_cursor`,
explicit missing ranges, and a byte count. A page can inspect at most 10,000
records and returns at most the configured byte limit.

## Pull streams

```elixir
{:ok, stream} =
  Jido.Harness.Session.stream(session_id,
    cursor: saved_cursor,
    limit: 100,
    poll_interval_ms: 50
  )
```

A slow consumer controls its own pace. Dropping a stream does not stop the
resource. A new consumer can attach with the saved cursor.

## Replay gaps

All resources use the native `jido.harness.replay.gap` Signal. Its payload has
`from`, `to`, and `reason`.

```elixir
case Jido.Harness.Signal.kind(signal) do
  :replay_gap -> reset_projection(signal.data["payload"])
  _kind -> apply_signal(signal)
end
```

A gap is a continuity boundary. It can report retention, an unavailable store,
or a record that did not fit the page byte limit.

## Memory and disk

The memory Signal tail and text tail are bounded. The default file store uses
8 MiB segments, a 256 MiB total limit, and a 24-hour terminal-resource TTL.
Retention options include `journal_dir`, `memory_bytes`, `segment_bytes`, and
`disk_limit_bytes`.

The V3 replay record format stores one sanitized native Signal as:

```elixir
%{"format_version" => 2, "sequence" => sequence, "signal" => signal_map}
```

It does not read the V2 Harness event format.

If disk storage fails, the resource continues with bounded sanitized memory.
A later read retries the store. Public replay and fallback use the same
redaction policy.

The ACP reader uses a separate demand-based live process Signal stream. It
keeps protocol bytes in memory and does not read the replay journal.

## Pruning and security

`prune/1` removes a terminal resource and its retained journal. Active
resources are not removed by the TTL sweep.

Journal paths use restrictive permissions. Stored provider activity can still
contain sensitive data. Protect journal directories and exported records.
