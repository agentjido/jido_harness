# Providers and capabilities

Harness includes eleven provider profiles. Every run and session uses ACP through
ExMCP. ACP can be part of the base CLI or a separate adapter program.

Use `Jido.Harness.providers/0` to inspect the bundled declarations. These
describe the selected Harness profile, not every feature of the base CLI.

## Provider inventory

| Provider | Atom | Base CLI | ACP entry point | Source | Profile maturity |
| --- | --- | --- | --- | --- | --- |
| Amp | `:amp` | `amp` | `amp-acp` | adapter | experimental |
| Antigravity CLI | `:antigravity` | `agy` | `refined-antigravity-acp` | adapter | experimental |
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

### Antigravity setup

Antigravity's `agy` CLI exposes no ACP mode, so this profile runs the
`refined-antigravity-acp` adapter, which drives Google's official
`agy_acp_server` binary. Two setup steps are required beyond installing the
adapter package.

First, provision the ACP server binary with the adapter's setup command. Read
and accept the Google Antigravity Terms of Service when it prompts:

```sh
refined-antigravity-acp setup
```

Setup also writes an editor profile for Zed and a Paseo configuration, and it
creates `~/.config/zed` when that directory is absent. Harness needs only the
binary, so expect those extra files on a harness-only machine.

Second, the ACP server authenticates separately from the `agy` CLI. It reads
its own `~/.gemini/antigravity-acp/settings.json` and ignores the CLI's keyring
session, so signing in with `agy` is not sufficient. For a Gemini API key,
merge this block into the settings file and export `GEMINI_API_KEY`:

```json
{"auth": {"type": "gemini-api-key"}}
```

For Agent Platform, use `auth.type: "agent-platform"` and `GOOGLE_API_KEY`,
or configure a project, location, and Application Default Credentials.
`GEMINI_HOME` changes the settings path to
`$GEMINI_HOME/antigravity-acp/settings.json`. Provider-configured environment
values also apply to readiness checks. A key alone is insufficient: readiness
reports authentication as false until a supported method is selected.

For Google OAuth, use an ACP client with browser-login support to authenticate
once through the same wrapper and with the same `GEMINI_HOME`. The wrapper
uses file credential storage. Harness reports configured OAuth as `:unknown`;
only a live request can prove the stored credentials work. Harness sends no
ACP `authenticate` method for this provider.

Model ids differ between the two layers. The CLI flattens reasoning effort into
the id, as in `gemini-3.8-flash-high`, while the adapter splits it apart. Pass
the base id as `model` and the effort as `reasoning_effort`. The adapter is
community maintained, so this profile is experimental. See the
[Antigravity CLI documentation](https://antigravity.google/docs/cli/install/).

Harness includes a crash guard for wrapper version 1.2.11. The wrapper can
otherwise report a server panic as a successful turn. The guard changes that
response to an ACP error and preserves the wrapper's recovery state. It is
loaded only for Antigravity through `NODE_OPTIONS`, which retains explicit
request values over provider configuration and the ambient environment.
Other Node packages inherit the module but receive no patch. An untested
version of the wrapper fails at startup. Recheck the guard when changing the
package pin.

## Separate ACP packages

`Jido.Harness.install/2` installs both the base CLI and these pinned ACP packages:

| Provider | ACP package |
| --- | --- |
| Amp | `amp-acp@0.9.0` |
| Antigravity CLI | `@simonepri/refined-antigravity-acp@1.2.11` |
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

Codex ACP 2.0.1 was also checked and does not expose these controls. For a
finite task, use the [native Codex process example](managed_processes.md#isolated-native-codex-task).
This uses the Codex CLI controls and the Harness process API.

Codex sandbox values select the ACP mode. Harness `approval_mode` controls
its permission responses. Environment replacement, sandbox mode, and saved
thread state are separate controls; see [Security](security.md).
