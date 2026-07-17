# Testing

Provider integration tests must balance deterministic lifecycle coverage with
explicit live verification. Jido.Harness supports both without running provider
requests during ordinary package startup or default unit tests.

## Unit tests with fake CLIs

Use deterministic executable fixtures to test:

- JSON/JSONL mapping;
- event ordering and terminal uniqueness;
- timeouts and cancellation;
- caller and consumer death;
- stdin, stdout, stderr, and PTY behavior;
- journal rotation and replay gaps;
- process-group cleanup.

Fake CLIs should accept structured argv and never require network access or
credentials. They make lifecycle regressions reproducible in pull-request CI.

## Non-billable provider readiness

```console
mix jido_harness.check
mix jido_harness.check --providers codex,kimi --strict
mix jido_harness.check --json
```

The check task never sends an agent prompt. Use it for developer setup, release
environment validation, or a non-billable CI readiness job.

## One minimal live query

```console
mix jido_harness.chat codex
mix jido_harness.chat codex --timeout 120 --json
```

The chat task sends one finite request through exactly one provider. It fails on
a provider error or empty response and may consume paid API or subscription
usage.

## Reusable integration contracts

```elixir
defmodule MyCodexIntegrationTest do
  use Jido.Harness.IntegrationCase, provider: :codex
  harness_contract_tests()
end
```

`Jido.Harness.IntegrationCase` generates tagged tests for status, minimal runs,
event ordering, terminal uniqueness, caller-independent lifecycle, cancellation,
resume, and interactive context where supported.

The package does not start ExUnit merely because `jido_harness` is loaded.

## Integration profiles

```console
JIDO_HARNESS_INTEGRATION_PROFILE=contract \
JIDO_HARNESS_INTEGRATION_PROVIDERS=codex,grok \
mix test --include integration test/integration/providers_test.exs \
  --timeout 7200000
```

Profiles are:

| Profile | Coverage |
| --- | --- |
| `smoke` | readiness and one minimal run |
| `contract` | canonical events, results, replay, and reattachment |
| `lifecycle` | caller death, resume, cancellation, and cleanup |
| `interactive` | live two-turn context through the selected session transport |

Set `JIDO_HARNESS_INTEGRATION_STRICT=true` to fail rather than skip when a
selected provider is unavailable.

## Soak testing

The deterministic soak profile runs for 65 minutes without contacting a
provider:

```console
mix test --include soak test/integration/soak_test.exs --timeout 7200000
```

It exercises long-lived lifecycle and retention behavior that short unit tests
cannot establish.

## Release verification

Before releasing an adapter change:

1. run deterministic unit and fixture contracts;
2. run the live smoke profile for the affected providers;
3. run lifecycle and interactive profiles when their transports changed;
4. run `mix quality`, `mix test`, `mix docs`, and `mix hex.build`.

See the exact [integration testing reference](../docs/integration_testing.md).
