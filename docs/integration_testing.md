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

## Readiness and inventory

Check registered provider readiness without making provider requests:

```console
mix jido_harness.check
mix jido_harness.check --providers codex,kimi
mix jido_harness.check --providers codex,kimi --install
```

The command reports installation, compatibility, authentication, smoke
readiness, and copyable installation recipes. Authentication can be `unknown`
when a CLI uses cached login; a smoke test is the definitive check.

Add the complete version inventory when needed:

```console
mix jido_harness.check --inventory
mix jido_harness.check --tools claude,codex,antigravity
mix jido_harness.check --inventory --strict
mix jido_harness.check --inventory --json
```

Inventory probes execute only each tool's version command through the harness
process manager. They report the resolved executable path, expected source,
update commands, and minimum tested version. Strict mode rejects missing,
failed, unrecognized, or older versions; newer versions pass.

The inventory covers Claude Code, Codex, Amp, Gemini CLI, Antigravity CLI, Kimi
Code, Grok, pi-coding-agent, Aider, Goose, and OpenCode. Antigravity, Aider, and
Goose remain probe-only: no provider adapter is registered and no contract or
live prompt is run for them.

## Ad hoc queries

Send a custom prompt through one provider:

```console
mix jido_harness.query codex "Explain this repository in one sentence."
```

Run the same deterministic check sequentially across selected or all registered
providers:

```console
mix jido_harness.query amp,claude,codex "Reply with exactly: ready" --expect ready
mix jido_harness.query all "Reply with exactly: ready" --expect ready --timeout 120
```

The task attempts every selected provider and reports the complete matrix before
failing if any run failed, returned empty text, or missed `--expect`. Additional
options include `--cwd`, `--model`, `--provider-session-id`, `--max-turns`,
`--idle-timeout`, `--env-file`, and `--json`. Timeout values are seconds. Query
runs are live provider work and may consume paid API or subscription usage.

Missing CLIs are printed with their exact recipe. Installation is opt-in:

```console
mix jido_harness.check --providers codex,kimi --install
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

Automated live requests are explicit integration profiles and may incur
provider usage:

```console
mix jido_harness.integration --providers codex --profile smoke
mix jido_harness.integration --providers amp,claude --profile contract
mix jido_harness.integration --profile lifecycle --strict
mix jido_harness.integration --providers kimi --profile smoke \
  --env-file /absolute/path/to/provider.env
```

Additional profiles include:

```console
mix jido_harness.integration --providers amp,claude --profile smoke
mix jido_harness.integration --profile contract
mix jido_harness.integration --profile lifecycle --strict
mix jido_harness.integration --profile interactive --provider all
mix jido_harness.integration --profile interactive --provider all --strict
mix jido_harness.integration --profile soak
```

Profiles are:

- `smoke`: status/readiness and one minimal run;
- `contract`: canonical events, result consistency, replay, and reattachment;
- `lifecycle`: caller death, resume where supported, cancellation, and cleanup;
- `interactive`: live two-turn context, interruption, session replay, and
  graceful close through each provider's selected session transport;
- `soak`: the deterministic local fixture for 65 minutes without provider cost.

## Interactive operator task

Open a headless interactive session for manual testing:

```console
mix jido_harness.chat codex
mix jido_harness.chat codex --transport app_server --format jsonl
mix jido_harness.chat kimi
```

The command set is `/send`, `/follow-up`, `/steer`, `/interrupt`, `/approve`,
`/deny`, `/status`, and `/close`. Unsupported commands return capability errors;
the task never falls back to screen-scraping or controlling a provider TUI.

Unavailable providers are non-fatal unless `--strict` is supplied. `--env-file`
loads simple `KEY=value` lines and never replaces an already-set variable. Keep
credential files outside the repository.

Pull-request CI runs the deterministic unit and short fixture suite. Live
provider tests are reserved for the manually triggered provider matrix.
