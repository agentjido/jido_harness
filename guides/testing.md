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
and long process-soak tests.

The escript fixture verifies native-helper extraction in a separate VM. The
[approval-policy recipe](recipes/policy_jobs.md) has fake-provider tests that
load its published source. See [CONTRIBUTING.md](../CONTRIBUTING.md) for setup,
coverage limits, and required checks.

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

It runs 50 timeouts and 400 short CLI processes without retries. A failure
includes the process state, stderr, and terminal events. The manual CI run
also runs this check on macOS with unmodified dependencies. It is excluded
from the default suite because erlexec 2.5.0 can fail this check on macOS;
see [Native process startup](reference/dependencies.md#native-process-startup).

For the longer retention and cleanup check:

```console
mix test --no-cover --include soak test/integration/soak_test.exs --timeout 7200000
```

This separate test runs for 65 minutes without contacting a provider. It checks
long-lived process, journal, and cleanup behavior.

## Release verification

Run deterministic checks for every change. For an adapter change, also run
the affected live smoke profile. Run lifecycle and interactive profiles when
the ACP entry point or lifecycle behavior changes. Soak checks cover longer
session and process lifetimes.

Record which live profiles ran and which were skipped. A passing unit suite
does not establish live compatibility. Review the
[dependency audit exceptions](reference/dependencies.md#audit-exceptions)
before publication.
