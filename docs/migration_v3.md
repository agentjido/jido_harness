# Migrate to version 3

Version 3 makes ACP the only coding-agent protocol. This is a hard cutover.
There is no runtime switch for the version 2 direct-CLI or session transport
paths.

GitHub issue `agentjido/jido_harness#61` owns this change.

PR #64 uses the ExMCP PR branch `codex/acp-original-message-context` from
`mikehostetler/ex_mcp` for original ACP message callbacks. The lockfile pins the
tested commit. The user approved this temporary Git dependency and the current
Cowlib audit exception. See [ACP v3 review status](decisions/acp-v3-open-gaps.md).
The Git dependency prevents a Hex package build until the ExMCP change is
released. Git-based development and validation use the locked PR commit.

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

Provider configuration from session creation or loading is retained as a
`provider_event` with kind `acp_session_configuration` and source `session_open`.
It describes the provider response before requested configuration changes.
Later configuration updates remain `acp_update` events. Treat a requested model
as a request; only provider data is evidence of the effective model.

The run, session, event, replay, retention, approval, and process lifecycle
types remain Harness types.

## Installation

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

The tested 2.x maintenance commit is
`adb3bce52ec97b14547cecc0434660b777e914ac` on `codex/harness-2x-maintenance`. It repairs OpenCode finite resume,
supports remote working-directory paths, and verifies provider model evidence.
Use that full commit ID when pinning a dependency. The proposed
tag is `v2.1.0-rc.2`, matching the source version; no tag or release was created.
Record the final reviewed commit and create the 2.x reference before merging v3.
