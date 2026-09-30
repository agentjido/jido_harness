# Providers and capabilities

Jido.Harness includes ten CLI providers. Every run and session uses ACP through
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
| Cursor CLI | `:cursor` | `cursor-agent` | `cursor-agent acp` | native | experimental |
| Gemini CLI | `:gemini` | `gemini` | `gemini --acp` | native | experimental |
| Grok | `:grok` | `grok` | `grok agent stdio` | native | stable |
| Kimi Code | `:kimi` | `kimi` | `kimi acp` | native | stable |
| OpenCode | `:opencode` | `opencode` | `opencode acp` | native | stable |
| Pi | `:pi` | `pi` | `pi-acp` | adapter | experimental |
| Z.AI | `:zai` | `claude` | `claude-agent-acp` | adapter | experimental |

Z.AI uses the Claude Code ACP adapter with the official Z.AI environment
mapping. It remains a separate `:zai` provider.

Cursor uses the stable `cursor-agent` binary name instead of the shorter
`agent` alias. This prevents command-name collisions with other providers.
Harness sends the documented `cursor_login` ACP authentication method before
it opens a session. Authenticate first with `cursor-agent login`, or set
`CURSOR_API_KEY` or `CURSOR_AUTH_TOKEN`. Cursor-specific blocking extension
methods are not normalized yet, so this profile is experimental. See the
[Cursor ACP documentation](https://cursor.com/docs/cli/acp).

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

## OpenCode model changes

OpenCode accepts `model` on runs and sessions. Use
`Jido.Harness.Session.configure(session_id, %{model: "provider/model"})` to
change a session model. Harness uses `session/set_config_option` with config ID
`model`. Older ACP agents can use `session/set_model` only when the config RPC
returns method not found. Other provider errors are returned to the caller.

## Codex isolation controls

Set `provider_options: %{ephemeral: true, ignore_user_config: true}` on a Codex
run or session to request a nonpersistent thread without user configuration.
Both options are optional booleans. An ephemeral request cannot load a saved
session. Workspace instructions remain active, and the workspace can remain
writable. `approval_mode` controls Harness permission responses; sandbox values
select the Codex ACP mode.

The ACP adapter must report the applied controls in
`agentCapabilities._meta.codex.isolation`. Harness returns a configuration error
before opening a session when a requested control is unavailable. The pinned
Codex ACP 1.6.2 package does not support these controls. An adapter with the
isolation extension can be selected with `acp_path`. Until upstream publishes
this extension, build [Codex ACP PR #569](https://github.com/agentclientprotocol/codex-acp/pull/569)
and use its executable.
Do not assume that an older adapter applies these environment controls.

```elixir
Jido.Harness.run(:codex, "Update the fixture",
  cwd: "/path/to/fixture",
  acp_path: "/path/to/isolation-capable/codex-acp",
  sandbox_mode: :workspace_write,
  approval_mode: :auto_approve,
  provider_options: %{ephemeral: true, ignore_user_config: true}
)
```
