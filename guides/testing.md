# Testing

Use fake CLIs for deterministic package checks. Use explicit live profiles to
verify installed providers. Live requests need credentials and can consume
API or subscription usage.

## Unit and fixture checks

```console
mix test
mix quality
mix docs --warnings-as-errors
mix hex.build
```

The default suite uses fixtures under `test/support/fixtures/`. It checks ACP
mapping, terminal events, caller exits, timeouts, stdin, output, PTY behavior,
journal rotation, replay gaps, and process cleanup. It excludes live provider
and long process-soak and replay-load tests.

The escript fixture verifies native-helper extraction in a separate VM. The
[approval-policy recipe](recipes/policy_jobs.md) has fake-provider tests that
load its published source. See [CONTRIBUTING.md](../CONTRIBUTING.md) for setup,
coverage limits, and required checks.

The coverage percentage excludes imported Erlang engine source. The 70% floor
continues to apply to Harness code. Native behavior has separate forced-error,
process lifecycle, and package checks.

The default Antigravity tests use a small protocol fixture. CI also installs
the pinned Node wrapper in a temporary directory and runs it against the fake
ACP backend. To run the same check locally, set
`HARNESS_TEST_ANTIGRAVITY_ACP_PATH` to the installed wrapper executable:

```console
mix test --no-cover --include antigravity_wrapper test/jido_harness/antigravity_test.exs
```

This check sends no model request and needs no credentials.

## Provider readiness

```console
mix jido_harness.check
mix jido_harness.check --providers codex,kimi --strict
mix jido_harness.check --json
```

| Option | Meaning |
| --- | --- |
| `--providers NAME,...` | Select providers; omitted means all registered providers |
| `--strict` | Fail if a selected provider is not ready |
| `--json` | Emit machine-readable output |

Readiness reports base-CLI installation, compatibility, authentication
evidence, and ACP executable availability. It sends no model prompt.
An `:unknown` authentication value requires a live request to establish
whether cached login works.

## One live request

```console
mix jido_harness.chat codex
mix jido_harness.chat codex "Explain this repository in one sentence."
mix jido_harness.chat codex --timeout 120 --json
```

This task requires one provider. Its default prompt is
`Reply with exactly: ready`. `--timeout` is in seconds. The task starts one
finite run and fails on provider error or empty text.

## Reusable integration contracts

```elixir
defmodule MyProviderIntegrationTest do
  use Jido.Harness.IntegrationCase, provider: :codex
  harness_contract_tests()
end
```

Generated tests are tagged `:integration` and have a two-hour watchdog.
Loading Harness does not start ExUnit or execute these tests.

## Select live coverage

```console
JIDO_HARNESS_INTEGRATION_PROFILE=lifecycle \
JIDO_HARNESS_INTEGRATION_PROVIDERS=codex,grok \
JIDO_HARNESS_INTEGRATION_STRICT=true \
mix test --no-cover --include integration test/integration/providers_test.exs \
  --timeout 7200000
```

| Profile | Coverage |
| --- | --- |
| `smoke` | Readiness and one minimal run |
| `contract` | Smoke checks, canonical events, results, replay, and reattachment |
| `lifecycle` | Contract checks plus caller death, resume, cancellation, and cleanup |
| `interactive` | Smoke checks and live two-turn ACP context |
| `soak` | Smoke checks and one long-lived ACP session per selected provider |

The default profile is `contract`. Unavailable providers can be skipped
unless strict mode is enabled. Resume and other optional checks still depend
on the selected profile's capabilities.

The manual live-integration workflow currently exposes `smoke`, `contract`,
and `lifecycle` for its configured provider matrix. Use the command above for
`interactive` or `soak` and for providers outside that matrix. The workflow
installs the base CLI and its required ACP entry point.

## Live session soak

Select `JIDO_HARNESS_INTEGRATION_PROFILE=soak` with the same command. The default
keeps each selected ACP session open for 10 minutes and sends a small turn every
minute. Provider modules run concurrently. Each turn checks response text,
session identity, process ownership, replay order, and terminal events.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `JIDO_HARNESS_LIVE_SOAK_DURATION_MS` | `600000` | Total session duration |
| `JIDO_HARNESS_LIVE_SOAK_INTERVAL_MS` | `60000` | Delay between completed turns |
| `JIDO_HARNESS_LIVE_SOAK_TURN_TIMEOUT_MS` | `600000` | Limit for one turn and startup wait |
| `JIDO_HARNESS_LIVE_SOAK_MAX_TURNS` | unset | Optional turn ceiling |

Use strict mode when a release check requires every selected provider to run.

## Deterministic process soak

Run the short startup regression check first:

```console
mix test --no-cover --include soak test/jido_harness/process_startup_regression_test.exs
```

The local check runs 50 timeouts and 400 short CLI processes without retries.
CI uses 250 timeouts and 2,000 short processes. A failure
includes the process state, stderr, and terminal events. Native CI runs this
check on macOS and Linux on every pull request and main push. It is excluded
from the default suite to keep local checks short.

The default suite also forces both child process-group outcomes in separate
Erlang VMs. A correct group must allow startup; a wrong group must prevent the
command from running. See the
[bundled native engine](reference/dependencies.md#bundled-native-process-engine).

For the longer retention and cleanup check:

```console
mix test --no-cover --include soak test/integration/soak_test.exs --timeout 7200000
```

This separate test runs for 65 minutes without contacting a provider. It checks
long-lived process, journal, and cleanup behavior.

## Journal replay load

Run the replay load suite without a provider or credentials:

```console
mix test --no-cover --include load test/jido_harness/journal_load_test.exs
```

The suite checks single-record pages at three journal sizes, concurrent readers
with different page sizes, and a growing journal with tail and empty polls. CI
runs it on macOS and Linux for each pull request and main push.

The checks use decode counts and file work. They do not use machine-specific
time limits to judge performance. Each single-record page must decode at most
64 records. A poll at the latest sequence must open no files and decode no
records. These checks detect a return to full-history scans. The default unit
suite also checks these bounds on a smaller journal.

Each `journal_load` JSON line reports elapsed microseconds, maximum replay
microseconds, decoded records, bytes passed to the decoder, files opened, and
the serialized index size. Use the same runtime, host, record count, and payload
size when you compare results. File caching and other work on the host affect
elapsed time. These values do not measure physical disk reads or total VM
memory.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `HARNESS_REPLAY_RECORDS` | `16000` | Largest journal and growing-tail record count |
| `HARNESS_REPLAY_READERS` | `4` | Concurrent readers; page sizes cycle through 1, 17, 100, and 257 |
| `HARNESS_REPLAY_PAYLOAD_BYTES` | `1024` | Payload bytes per record |

For a larger local check:

```console
HARNESS_REPLAY_RECORDS=64000 HARNESS_REPLAY_READERS=8 \
mix test --no-cover --include load test/jido_harness/journal_load_test.exs
```

The suite uses temporary journal directories and removes them after each test.
Use the replay telemetry event to measure work in a running application. See
the [telemetry reference](reference/telemetry.md).

## Harness load without CLI processes

```console
mix test --no-cover --include load test/jido_harness/harness_load_test.exs
```

This suite uses synthetic ACP frames, BEAM tasks, and temporary journals. It
starts no CLI process and makes no network or model request. It checks:

- one-byte frame fragments and text deltas at increasing sizes;
- 5,000 frames with a slow reader, bounded queue bytes, and ordered delivery;
- closing a paused reader;
- 2,000 completed turns with fixed result and event budgets;
- cleanup of 1,000 and 10,000 waiting callers;
- event encoding and secret removal at 1 KiB and 16 KiB payload sizes;
- 3,000 live process events through a BEAM driver with no journal replay.

Set `HARNESS_LOAD_BYTES` to increase the largest fragmentation input. The
default is 262,144 bytes. Reduction counts check work growth without a fixed
time threshold. Each `harness_load` JSON line reports the scenario, elapsed
microseconds, reductions, and relevant byte or count limits. These values
describe the measured process and retained data, not total VM memory.
CI runs this suite and the journal load suite on Linux and macOS.

The default unit suite checks the direct ACP read path with a BEAM process
driver. It checks original wire bytes, no journal replay, terminal delivery,
gap reporting, and cleanup after a waiting caller exits.

## Release verification

Run deterministic checks for every change. For an adapter change, also run
the affected live smoke profile. Run lifecycle and interactive profiles when
the ACP entry point or lifecycle behavior changes. Soak checks cover longer
session and process lifetimes.

Record which live profiles ran and which were skipped. A passing unit suite
does not establish live compatibility. Review the
[dependency audit](reference/dependencies.md#dependency-audit)
before publication.

## Replay store measurements

Shared contract tests run in `mix test`. CI also runs the store load suite on
Linux and macOS. Run the load check without provider tools:

```bash
mix test --no-cover --include load test/jido_harness/replay_store_load_test.exs
```

The check compares 2,000 and 16,000 retained records and uses reductions to
bound read work. It does not apply a machine-dependent latency threshold.

Run the memory comparison separately:

```bash
mix run bench/replay_store.exs
HARNESS_STORE_RECORDS=64000 HARNESS_STORE_READS=2000 mix run bench/replay_store.exs
```

The benchmark compares the original queue buffer, indexed worker memory, and
ETS with 1 and 32 resources and 256-byte and 4-KiB payloads. Each resource has
its own owner process. Output reports append, tail-read, and empty-read time
and reductions, retained counts, logical bytes, process and ETS memory, VM
memory snapshots, queue length, and memory after cleanup. Byte limits default
to 4 MiB per resource (`HARNESS_STORE_BYTES`). Record counts default to 16,000
across resources, and each owner performs 1,000 reads of each kind. Many-owner
times are summed worker times, not aggregate wall-clock throughput.

Repeated payload binaries are shared. Logical budgets and VM memory differ;
allocator behavior and other VM processes affect total memory snapshots. The
queue baseline uses external-term-size retention; adapters use JSON bytes.
Compare retained counts as well as memory. These are synthetic measurements,
not estimates of provider latency or guarantees for production workloads.
