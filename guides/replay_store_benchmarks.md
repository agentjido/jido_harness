# Replay store benchmark results

This is one local synthetic run on 2026-10-16 with OTP 29, Elixir 1.20.4,
10 schedulers, and an 8-byte VM word. It uses no provider processes.
These times describe this host and are not regression thresholds.

Reproduce with:

```bash
mix run bench/replay_store.exs
```

The script warms the shared code, then uses new owner processes for every
measurement. It appends 16,000 records across 1 or 32 owners, with a 4 MiB
logical budget per owner. Each owner performs 1,000 one-record tail reads and
1,000 caught-up reads. Repeated payload binaries are shared. Memory below is
worker memory plus ETS table memory after garbage collection; it excludes
shared binary memory and other VM processes. The script also reports whole-VM
snapshots to show that distinction.

## One resource

Times are milliseconds for each full phase. Read phases each contain 1,000
reads. The queue baseline uses external-term-size budgets; stores use JSON
bytes. Retained counts therefore differ slightly.

| Payload | Implementation | Retained events | Append ms | Tail reads ms | Empty reads ms | Worker + ETS bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 256 B | Buffer | 13,189 | 3.36 | 537.03 | 533.04 | 2,546,328 |
| 256 B | Memory | 13,732 | 25.16 | 0.32 | 0.18 | 1,574,032 |
| 256 B | ETS | 13,732 | 19.72 | 0.98 | 0.25 | 4,068,648 |
| 4 KiB | Buffer | 1,008 | 2.74 | 41.19 | 39.85 | 142,680 |
| 4 KiB | Memory | 1,011 | 191.49 | 0.41 | 0.38 | 142,680 |
| 4 KiB | ETS | 1,011 | 154.47 | 1.20 | 0.57 | 303,232 |

The queue has cheaper appends, but both read paths scan its retained prefix.
Indexed stores remove that scan. Prepared JSON byte accounting adds append
work compared with the queue's external term size. Cached sizes avoid encoding
retained records again during memory reads.

## Thirty-two resources

Each owner appends 500 records. These memory totals include all 32 workers and
all their ETS tables. Timing values are summed worker times under concurrent
load, not overall wall-clock throughput.

| Payload | Implementation | Append ms sum | Tail reads ms sum | Empty reads ms sum | Worker + ETS bytes | After cleanup bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 256 B | Buffer | 16.61 | 5841.12 | 1877.85 | 2,831,872 | 86,272 |
| 256 B | Memory | 113.91 | 16.61 | 13.10 | 2,831,872 | 86,272 |
| 256 B | ETS | 130.53 | 46.59 | 12.54 | 4,863,232 | 89,856 |
| 4 KiB | Buffer | 22.78 | 3001.75 | 1236.09 | 2,831,872 | 86,272 |
| 4 KiB | Memory | 606.98 | 14.51 | 12.83 | 2,831,872 | 86,272 |
| 4 KiB | ETS | 669.10 | 54.64 | 18.68 | 4,863,232 | 89,856 |

All scenarios reported zero queued messages at the retained-state snapshot.
Explicit ETS cleanup left zero bytes in owned ETS tables. Worker memory fell
to a small process baseline after cleanup; VM allocator memory need not return
to its starting value.

## Decision

Keep file storage as the default. Use the indexed worker tree for the sanitized
fallback. ETS is available through explicit configuration. It reduces worker
heap residency, but used more total memory and had slower tail reads than the
tree in this run. Its append advantage in some cases does not justify changing
the default. Measure representative application records before selecting it.

The load test gates indexed read work as history grows. Benchmark timings stay
outside the default test suite. See [Testing](testing.md#replay-store-measurements)
for configuration and limits of these measurements.
