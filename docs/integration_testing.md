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

Start with the live operator task. With no flags it only runs non-billable
version and readiness probes for all registered providers:

```console
mix jido_harness.live
mix jido_harness.live --providers codex,kimi
```

It reports whether each CLI is installed and compatible, whether an API-key
environment variable proves authentication, and whether the adapter is ready
for a smoke request. Authentication can be `unknown` when a CLI uses cached
login; a smoke test is the definitive check.

Missing CLIs are printed with their exact recipe. Installation is opt-in:

```console
mix jido_harness.live --providers codex,kimi --install
```

The built-in recipes are:

| Provider | Installation |
| --- | --- |
| Amp | `npm install --global @sourcegraph/amp` |
| Claude Code | `npm install --global @anthropic-ai/claude-code` |
| Codex | `npm install --global @openai/codex` |
| Gemini CLI | `npm install --global @google/gemini-cli` |
| Grok | `npm install --global @xai-official/grok` |
| Kimi Code | `npm install --global @moonshot-ai/kimi-code` |
| OpenCode | `npm install --global opencode-ai` |
| Pi | `npm install --global --ignore-scripts @earendil-works/pi-coding-agent` |
| Z.AI | `npm install --global @anthropic-ai/claude-code` |

Z.AI uses the officially supported Claude Code integration, so Claude and Z.AI
share one CLI installation. Follow the provider documentation link printed by
the task for cached login or API-key setup.

Live requests require `--test` and may incur provider usage:

```console
mix jido_harness.live --providers codex --test --profile smoke
mix jido_harness.live --providers amp,claude --test --profile contract
mix jido_harness.live --test --profile lifecycle --strict
mix jido_harness.live --providers kimi --test --profile smoke \
  --env-file /absolute/path/to/provider.env
```

The live task delegates execution to the lower-level integration runner:

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
