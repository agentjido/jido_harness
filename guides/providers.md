# Providers and capabilities

Jido.Harness includes nine CLI providers. Every run and session uses ACP through
ExMCP. A provider can supply ACP in its base CLI or through a separate adapter
program.

This distinction also controls the source of `Event.raw`. A native ACP provider
writes the retained ACP message. For an adapter-backed provider, the adapter
writes it after it translates the provider's native protocol. Native fields
that the adapter does not include in its ACP message are not available to
Harness.

Use `Jido.Harness.providers/0` to inspect the declarations.

## Provider inventory

| Provider | Atom | Base CLI | ACP entry point | Source | Maturity |
| --- | --- | --- | --- | --- | --- |
| Amp | `:amp` | `amp` | `amp-acp` | adapter | experimental |
| Claude Code | `:claude` | `claude` | `claude-agent-acp` | adapter | stable |
| Codex | `:codex` | `codex` | `codex-acp` | adapter | stable |
| Gemini CLI | `:gemini` | `gemini` | `gemini --acp` | native | experimental |
| Grok | `:grok` | `grok` | `grok agent stdio` | native | stable |
| Kimi Code | `:kimi` | `kimi` | `kimi acp` | native | stable |
| OpenCode | `:opencode` | `opencode` | `opencode acp` | native | stable |
| Pi | `:pi` | `pi` | `pi-acp` | adapter | experimental |
| Z.AI | `:zai` | `claude` | `claude-agent-acp` | adapter | experimental |

Z.AI uses the Claude Code ACP adapter with the official Z.AI environment
mapping. It remains a separate `:zai` provider.

## Capability declarations

`ACPAgentSpec.capabilities` is the source of truth for session loading,
follow-up turns, interruption, approvals, multimodal input, MCP servers, usage,
and dynamic configuration. Unsupported operations fail before provider
dispatch. Capabilities can differ, but the Harness API is the same.

## Readiness

```elixir
{:ok, status} = Jido.Harness.status(:codex)
status.session_ready
Jido.Harness.ProviderStatus.ready?(status)
```

The first value reports the ACP executable. The second value requires both the
base CLI and ACP executable. Status checks do not send a model prompt.

```console
mix jido_harness.check --providers codex,kimi --strict
```

For an adapter-backed provider, the check output gives one installation command
for the base CLI and one for the ACP adapter.

## Normalized options

Each `ACPAgentSpec` declares the session, turn, and configuration fields that it
can represent. Provider escape hatches stay under `provider_options` and are
also declared. Unknown options fail. Harness does not pass old direct-CLI flags
to an ACP adapter.

## Provider selection

Jido.Harness does not rank providers, retry billable work, or fall back to a
second provider. Pass a provider atom or configure one default.
