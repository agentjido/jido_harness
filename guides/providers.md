# Providers and capabilities

Harness includes ten provider profiles. Every run and session uses ACP through
ExMCP. ACP can be part of the base CLI or a separate adapter program.

Use `Jido.Harness.providers/0` to inspect the bundled declarations. These
describe the selected Harness profile, not every feature of the base CLI.

## Provider inventory

| Provider | Atom | Base CLI | ACP entry point | Source | Profile maturity |
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

Maturity is profile metadata. It does not establish that live tests ran for
every installed CLI version. Use [Testing](testing.md) to verify the providers
required by a release.

## Separate ACP packages

`Jido.Harness.install/2` installs both the base CLI and these pinned ACP packages:

| Provider | ACP package |
| --- | --- |
| Amp | `amp-acp@0.9.0` |
| Claude Code | `@agentclientprotocol/claude-agent-acp@0.70.0` |
| Codex | `@agentclientprotocol/codex-acp@1.6.2` |
| Pi | `pi-acp@0.0.33` |
| Z.AI | `@agentclientprotocol/claude-agent-acp@0.70.0` |

Preview installation with `Jido.Harness.install(provider, dry_run: true)`.
Native profiles use the base CLI's ACP command.

Z.AI remains a separate provider. It uses the Claude ACP adapter with the
[Z.AI Claude configuration](https://docs.z.ai/devpack/tool/claude) mapping for
`ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`.

Cursor uses `cursor-agent` to avoid collisions with other `agent` commands.
Harness selects the `cursor_login` authentication method. Log in first with
the installed Cursor CLI, or supply `CURSOR_API_KEY` or `CURSOR_AUTH_TOKEN`.
Cursor extension methods are not normalized in this profile. See
[Cursor ACP authentication](https://cursor.com/docs/cli/acp).

## Readiness

```elixir
{:ok, status} = Jido.Harness.status(:codex)
{status.session_ready, Jido.Harness.ProviderStatus.ready?(status)}
```

`session_ready` reports ACP executable availability. `ready?/1` requires base
CLI and ACP readiness. Authentication can be `:unknown` when inspection
cannot establish cached login. A live request is still needed to prove the
provider can execute a task.

```console
mix jido_harness.check --providers codex,kimi --strict
```

Readiness sends no model prompt. The check output includes installation
guidance for both components of a separate-adapter profile.

## Options and capabilities

`AdapterSpec` declares normalized request fields and provider extensions.
`ACPAgentSpec` declares session, turn, and configuration options and
`SessionCapabilities`. Unsupported values fail before dispatch.

The current profiles differ in model configuration, resume, attachments,
usage, MCP support, and approvals. Inspect the selected declaration:

```elixir
spec = Enum.find(Jido.Harness.providers(), &(&1.provider == :codex))

%{
  request_options: spec.normalized_options,
  session_options: spec.acp_agent.session_options,
  configuration_options: spec.acp_agent.configuration_options,
  capabilities: spec.acp_agent.capabilities
}
```

Steering is unavailable in the current ACP path. No built-in profile supports
structured output. Finite runs reject manual `approval_mode: :prompt`; see
[Runs](runs.md) and the [approval-policy recipe](recipes/policy_jobs.md).

Unknown options return errors. Old direct-CLI flags are not passed through
to an ACP adapter. Harness does not select providers, retry paid work, or fall
back to another provider.

For a separate ACP adapter, `Event.raw` is the adapter's translated ACP message.
Native fields it omits are unavailable. See the
[event reference](reference/event_reference.md#provider-events-and-replay-gaps).

## OpenCode model changes

OpenCode supports initial and runtime model configuration:

```elixir
Jido.Harness.Session.configure(session_id, %{model: "provider/model"})
```

Harness uses `session/set_config_option` with config ID `model`. It tries
`session/set_model` only when the config RPC returns method not found.
Other provider errors are returned to the caller. Use a model available to the
selected provider.

## Codex isolation controls

The optional `provider_options` booleans `ephemeral` and
`ignore_user_config` request a thread without saved state and without user
configuration. An ephemeral request cannot load a saved session. Workspace
instructions remain active.

The pinned Codex ACP 1.6.2 package does not support these controls. Requesting
them returns a configuration error before session creation. Harness requires
the initialize response to report applied controls in
`agentCapabilities._meta.codex.isolation`.

A custom ACP executable can be selected with `acp_path`. Verify its isolation
behavior before use. The presence of these request fields does not establish
isolation support in the pinned package.

Codex sandbox values select the ACP mode. Harness `approval_mode` controls
its permission responses. Environment replacement, sandbox mode, and saved
thread state are separate controls; see [Security](security.md).
