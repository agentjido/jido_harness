# Migrate to version 3

Version 3 makes ACP the only coding-agent protocol. This is a hard cutover.
There is no runtime switch for the version 2 direct-CLI or session transport
paths.

GitHub issue `agentjido/jido_harness#61` owns this change.

PR #64 uses ExMCP 1.3 for ACP message-context callbacks. ExMCP 1.3 contains the
reviewed PR #32 change and passed its release qualification workflow. The
current Cowlib audit exception remains in effect.
See [ACP v3 review status](decisions/acp-v3-open-gaps.md).

## Execution model

Both public workflows use the same core:

```text
RunRequest or SessionRequest
          -> ACPAgentSpec
          -> Harness-owned process
          -> ExMCP ACP client
          -> normalized Harness events
```

`Jido.Harness.run/3` opens a temporary ACP session and sends one turn.
`Jido.Harness.Session` keeps the ACP session open for more turns. Harness still
owns runs, sessions, events, replay, retention, approval IDs, approval timeouts,
and process lifecycle.

## Breaking changes

- Custom adapters no longer implement `run/2` or `cancel/2`.
- Each `AdapterSpec` must declare one `acp_agent`.
- `SessionRequest.transport` is removed.
- `AdapterSpec.default_session_transport` and `session_transports` are removed.
- `SessionTransportSpec` and `InteractionCapabilities` are removed.
- Managed resume transports and Pi JSONL RPC sessions are removed.
- `SessionInfo.transport` is removed because ACP is the only value.
- A finite run rejects `max_turns`; one run is one ACP prompt.
- Version 2 Codex structured output is not available through ACP and now returns
  a capability error.
- Old provider options that only changed direct CLI argv are not passed to ACP.
- Finite runs reject `approval_mode: :prompt`. Use a stateful session for manual
  approval responses. A finite run approves requests only in `:auto_approve`
  mode and denies them in other modes.

A finite job can still use host policy for approvals. Load
`examples/policy_job.exs` from the repository and call
`Jido.Harness.Examples.PolicyJob.run/4`. It uses one session and one bounded turn,
denies failed or timed-out policy decisions, and closes the session on exit.
The turn budget begins after startup. This does not add approval callbacks to
the finite Run API.

The example handles permission requests that the provider sends. It does not
set a provider approval mode. Configure provider permissions to request host
approval where needed. Provider options passed in `session_options` must be
supported by that provider; OpenCode, for example, does not accept the normalized
`approval_mode` option. Session still supports its ACP permission requests.

Provider configuration from session creation or loading is retained as a
`provider_event` with kind `acp_session_configuration` and source `session_open`.
It describes the provider response before requested configuration changes.
Later configuration updates remain `acp_update` events. Treat a requested model
as a request; only provider data is evidence of the effective model.

The run, session, event, replay, retention, approval, and process lifecycle
types remain Harness types.

`Event.raw` now represents the decoded message at the ACP boundary. For a
native ACP provider, this is the provider's ACP message. For an adapter-backed
provider, this is the ACP message that the adapter constructed from its native
protocol. It is not the unmodified native-provider event. A provider field that
the adapter does not map is unavailable. Applications that used native raw
fields from a 2.x direct-CLI adapter must review this change.

## Installation

Jido.Harness is not published on Hex. Version 2 remains available through an
immutable Git tag during the transition. Version 3 will be the first planned
Hex release line.

To test version 3 before its Harness Hex release, add the Git dependency to
your application's `mix.exs`:

```elixir
{:jido_harness, github: "agentjido/jido_harness", branch: "main"}
```

Run `mix deps.get` and commit your application's `mix.lock`. For a fixed Harness
revision, replace `branch:` with `ref:` and the full reviewed Harness commit ID.
Harness selects ExMCP `~> 1.3` from Hex. A separate ExMCP override is not needed
when Harness is its only consumer.

If your application already declares ExMCP, use a compatible Hex requirement.
Check other packages that use ExMCP before adding an override.

Some base CLIs include ACP. Other providers need a separate ACP adapter.

```elixir
Jido.Harness.install(:codex, dry_run: true)
```

For an adapter-backed provider, the result contains `:cli` and `:acp`
components. Install both. `mix jido_harness.check` reports the same two-part
readiness state.

The built-in adapter-backed profiles use exact package versions:

| Provider | ACP package |
| --- | --- |
| Amp | `amp-acp@0.9.0` |
| Claude Code | `@agentclientprotocol/claude-agent-acp@0.70.0` |
| Codex | `@agentclientprotocol/codex-acp@1.6.2` |
| Pi | `pi-acp@0.0.33` |
| Z.AI | `@agentclientprotocol/claude-agent-acp@0.70.0` |

## Custom adapter update

1. Remove the adapter `run/2` and `cancel/2` callbacks.
2. Add an `ACPAgentSpec.native/3` or `ACPAgentSpec.adapter/3` value.
3. Declare only options and capabilities that the ACP entry point supports.
4. Add `acp_env/2` only for required credential or endpoint mapping.
5. Test runs and sessions with the same fake ACP executable.

## Rollback

Stay on Jido.Harness 2.x when an essential CLI has no usable ACP entry point.
Version 3 does not fall back to a direct provider protocol.

The supported 2.x release is `v2.1.0-rc.2` at merge commit
`cea12d9132f0cf954deb329ec81a0e187332edb6`. It repairs OpenCode finite resume,
supports remote working-directory paths, and verifies provider model evidence.
Use the tag when pinning a version 2 dependency.

## Release sequence

1. Merge the version 3 change after its required checks pass.
2. Create the annotated `v3.0.0-rc.1` Git tag from the reviewed merge revision.
   A tag push runs the release checks and a Hex package dry run.
3. Publish that same tag as the first Hex package only after explicit release
   approval. A separate release workflow dispatch performs the publication.
