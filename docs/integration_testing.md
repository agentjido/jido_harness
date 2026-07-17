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
| `interactive` | live two-turn context through the selected transport |

Unavailable providers are skipped unless strict mode is enabled.

## Soak profile

```console
mix test --include soak test/integration/soak_test.exs --timeout 7200000
```

The deterministic soak runs for 65 minutes and does not contact a provider. It
exercises long-lived process, run, session, journal, and cleanup behavior.

## CI boundary

Pull-request CI should run deterministic unit and fixture tests. Live provider
profiles remain explicit because they require installed CLIs, credentials, and
potentially billable usage.
