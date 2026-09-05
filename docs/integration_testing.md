# Integration testing reference

Jido.Harness separates non-billable readiness, one-provider live queries,
profiled provider contracts, and deterministic soak testing.

## Readiness task

```console
mix jido_harness.check
mix jido_harness.check --providers codex,kimi --strict
mix jido_harness.check --json
```

Options:

| Option | Meaning |
| --- | --- |
| `--providers NAME,...` | select providers; omitted means all registered providers |
| `--strict` | fail when a selected provider is not ready |
| `--json` | emit machine-readable output |

The task reports installation, compatibility, authentication evidence,
readiness, version, executable, and installation guidance. It never sends an
agent prompt.

## Minimal live task

```console
mix jido_harness.chat codex
mix jido_harness.chat codex "Explain this repository in one sentence."
mix jido_harness.chat codex --timeout 120 --json
```

The task requires exactly one provider. With no custom prompt it sends `Reply
with exactly: ready`. It starts one finite harness run, fails on provider error
or empty text, and may consume paid usage.

## IntegrationCase

```elixir
defmodule MyProviderIntegrationTest do
  use Jido.Harness.IntegrationCase, provider: :codex
  harness_contract_tests()
end
```

Generated tests are tagged `:integration` and use a two-hour watchdog. They can
verify status, a minimal run, event order, terminal uniqueness, caller-detached
lifecycle, cancellation, resume, and interactive context.

Loading Jido.Harness does not start ExUnit or run these tests.

## Profiles

Select live coverage with environment variables:

```console
JIDO_HARNESS_INTEGRATION_PROFILE=lifecycle \
JIDO_HARNESS_INTEGRATION_PROVIDERS=codex,grok \
JIDO_HARNESS_INTEGRATION_STRICT=true \
mix test --include integration test/integration/providers_test.exs \
  --timeout 7200000
```

| Profile | Contract |
| --- | --- |
| `smoke` | readiness and one minimal run |
| `contract` | canonical events, result consistency, replay, reattachment |
| `lifecycle` | caller death, resume, cancellation, cleanup |
| `interactive` | live two-turn context through the ACP entry point |
| `soak` | one long-lived live ACP session per selected provider |

Unavailable providers are skipped unless strict mode is enabled.

## Soak profiles

The live ACP soak is opt-in and may consume paid usage:

```console
JIDO_HARNESS_INTEGRATION_PROFILE=soak \
JIDO_HARNESS_INTEGRATION_PROVIDERS=amp,claude,codex,gemini,grok,kimi,opencode,pi,zai \
mix test --include integration test/integration/providers_test.exs \
  --timeout 7200000
```

Each provider keeps one Harness-owned ACP process and session open for 10
minutes. It sends one bounded token-response turn every minute. Provider
modules run concurrently. Each turn verifies response text, stable ACP session
identity, process ownership, ordered replay, and terminal turn events.

The live soak accepts these controls:

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `JIDO_HARNESS_LIVE_SOAK_DURATION_MS` | `600000` | total session duration |
| `JIDO_HARNESS_LIVE_SOAK_INTERVAL_MS` | `60000` | delay between completed turns |
| `JIDO_HARNESS_LIVE_SOAK_TURN_TIMEOUT_MS` | `600000` | limit for one turn and session startup |
| `JIDO_HARNESS_LIVE_SOAK_MAX_TURNS` | unset | optional turn ceiling for a bounded check |

Unavailable providers are skipped unless strict mode is enabled. Use strict
mode for a release gate that requires all selected credentials and ACP entry
points.

The deterministic process soak remains separate and does not contact a
provider:

```console
mix test --include soak test/integration/soak_test.exs --timeout 7200000
```

It runs for 65 minutes and exercises long-lived process, journal, and cleanup
behavior without paid usage.

## CI boundary

Pull-request CI should run deterministic unit and fixture tests. Live provider
profiles remain explicit because they require installed CLIs, credentials, and
potentially billable usage.
