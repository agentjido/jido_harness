# Integration testing

`Jido.Harness.IntegrationCase` is public ExUnit support. Loading the package does
not start ExUnit or run provider tests.

```elixir
use Jido.Harness.IntegrationCase, provider: :codex
harness_contract_tests()
```

Generated tests are tagged `:integration`, use a two-hour watchdog, and verify
status, a minimal run, event ordering, terminal uniqueness, caller-detached
lifecycle behavior, cancellation, resume, and interactive context.

## Provider readiness

Check registered providers without sending a prompt:

```console
mix jido_harness.check
mix jido_harness.check --providers codex,kimi --strict
mix jido_harness.check --json
```

The task reports installation, compatibility, authentication, readiness, and
version information. Authentication can be `unknown` when a CLI uses cached
login; a live query is definitive. Missing providers include their installation
recipe or documentation URL.

## Minimal live queries

Send the default `Reply with exactly: ready` prompt through one provider:

```console
mix jido_harness.chat codex
```

Pass a custom prompt or request JSON output:

```console
mix jido_harness.chat codex "Explain this repository in one sentence."
mix jido_harness.chat codex --timeout 120 --json
```

Each invocation starts one finite harness run through exactly one registered
provider. The task fails when that provider fails or returns no text. Live
queries may consume paid API or subscription usage.

## Full integration profiles

The integration tests remain ordinary opt-in ExUnit tests. Select a profile and
provider set with environment variables:

```console
JIDO_HARNESS_INTEGRATION_PROFILE=smoke \
JIDO_HARNESS_INTEGRATION_PROVIDERS=codex,grok \
mix test --include integration test/integration/providers_test.exs --timeout 7200000
```

Supported profiles are:

- `smoke`: status/readiness and one minimal run;
- `contract`: canonical events, result consistency, replay, and reattachment;
- `lifecycle`: caller death, resume where supported, cancellation, and cleanup;
- `interactive`: live two-turn context through each provider's selected session
  transport.

Set `JIDO_HARNESS_INTEGRATION_STRICT=true` to reject unavailable providers.
These profiles may consume provider usage.

The deterministic 65-minute soak test is separate and does not contact a
provider:

```console
mix test --include soak test/integration/soak_test.exs --timeout 7200000
```

Pull-request CI runs the deterministic unit and short fixture suite. Live
provider tests remain explicit.
