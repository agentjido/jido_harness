# Integration testing

`Jido.Harness.IntegrationCase` is public ExUnit support. Loading the package does
not start ExUnit or run provider tests.

```elixir
use Jido.Harness.IntegrationCase, provider: :codex
harness_contract_tests()
```

Generated tests are tagged `:integration`, use a two-hour watchdog, and verify
status, a minimal run, event ordering, terminal uniqueness, and caller-detached
lifecycle behavior.

## Mix task

```console
mix jido_harness.integration --providers amp,claude --profile smoke
mix jido_harness.integration --profile contract
mix jido_harness.integration --profile lifecycle --strict
mix jido_harness.integration --profile soak
```

Profiles are:

- `smoke`: status/readiness and one minimal run;
- `contract`: canonical events, result consistency, replay, and reattachment;
- `lifecycle`: caller death, resume where supported, cancellation, and cleanup;
- `soak`: the deterministic local fixture for 65 minutes without provider cost.

Unavailable providers are non-fatal unless `--strict` is supplied. `--env-file`
loads simple `KEY=value` lines and never replaces an already-set variable. Keep
credential files outside the repository.

Pull-request CI runs the deterministic unit and short fixture suite. Live
provider tests are reserved for the manually triggered provider matrix.
