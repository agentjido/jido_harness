# Migrate to version 3

Version 3 uses ACP for every coding-agent run and session. It has no switch
back to the version 2 direct-CLI or alternative session transports. The host
application still receives Harness requests, events, results, and errors.

## Update a version 2 application

| Previous behavior | Version 3 action |
| --- | --- |
| Custom adapter `run/2` and `cancel/2` | Declare one `ACPAgentSpec`; Harness owns execution and cancellation |
| `SessionRequest.transport` | Remove it; all sessions use ACP |
| `AdapterSpec.default_session_transport` and `session_transports` | Replace them with `acp_agent` |
| `SessionTransportSpec` and `InteractionCapabilities` | Use `ACPAgentSpec` and `SessionCapabilities` |
| `SessionInfo.transport` | Remove field access |
| Managed resume or Pi JSONL RPC transport | Use the provider's ACP entry point |
| `max_turns` on a finite run | Remove it; one run sends one ACP turn |
| Direct-CLI provider flags | Use only declared normalized or provider options |

The run, session, event, replay, retention, and process lifecycle APIs remain
Harness APIs. Review [Providers](../providers.md) for the exact ACP executables
and pinned adapter packages.

## Approvals

Finite runs reject `approval_mode: :prompt`. They approve ACP permission
requests only in `:auto_approve` mode and deny them in other modes.

Use [Interactive sessions](../interactive_sessions.md) for manual approval
responses. The tested [policy job recipe](../recipes/policy_jobs.md) uses one
bounded session turn when host code must decide each request. It closes the
session on exit.

Only answer permission requests the provider sends. Provider options must be
supported by its profile. OpenCode supports ACP permission requests but does
not accept the normalized `approval_mode` field.

## Structured output and isolation

No built-in version 3 ACP profile supports structured output. Requests for
`structured_output` fail before agent execution. The retained request and
result fields do not establish support.

The pinned Codex ACP profile also does not implement the optional ephemeral
and ignore-user-config controls. See [Codex isolation controls](../providers.md#codex-isolation-controls)
before relying on them. A custom ACP executable must report the applied
controls.

Keep a version 2 dependency when its direct-Codex structured-output contract
is required. Version 3 has no direct-CLI fallback.

## Raw events and model evidence

`Event.raw` now contains the decoded message at the ACP boundary. For a
separate ACP adapter, it contains the adapter's translated message.
Provider-native fields omitted during translation are unavailable.

Session-open configuration is retained as a `:provider_event` with kind
`acp_session_configuration` and source `session_open`. It describes the
response before requested configuration changes. Later updates use
`acp_update`. A requested model alone does not prove which model ran.

Review the [event reference](../reference/event_reference.md) if your
application reads raw fields or provider model evidence.

## Earlier provider packages

Applications migrating from provider namespaces such as `Jido.Amp` should use
the common `Jido.Harness` facade and its Run, Session, and Process modules.
Replace provider SDK result and event structs with `RunResult`, `TurnResult`,
`Event`, and `Error`.

Keep Harness resource IDs separate from `provider_session_id`. Move workspace
provisioning and retry policy to the host application. Replace shell templates
with executable-plus-argv processes. Remove old adapter discovery, Jido Action
or Signal wrappers, and Splode error matching. Supply an existing working
directory.

## Install and verify

Follow [Getting started](../getting_started.md) for the release-candidate
dependency and CLI setup. Some providers need both a base CLI and a separate
ACP adapter. Preview both with `Jido.Harness.install(provider, dry_run: true)`.

Harness uses ExMCP `~> 1.3` from Hex. If another application dependency also
uses ExMCP, check compatible requirements before adding an override.
Review [dependency audit exceptions](../reference/dependencies.md#audit-exceptions).

For a custom adapter, follow [Custom adapters](../custom_adapters.md).
Run the deterministic and affected live checks in [Testing](../testing.md).

## Keep version 2 when required

The version 2.1 release candidate is tagged `v2.1.0-rc.2` at commit
`cea12d9132f0cf954deb329ec81a0e187332edb6`:

```elixir
{:jido_harness, github: "agentjido/jido_harness", tag: "v2.1.0-rc.2"}
```

The tag keeps the historical
[version 2 migration guide](https://github.com/agentjido/jido_harness/blob/v2.1.0-rc.2/docs/migration_v2.md),
[structured-output contract](https://github.com/agentjido/jido_harness/blob/v2.1.0-rc.2/docs/structured_output_execution.md),
and [schema-isolation decision](https://github.com/agentjido/jido_harness/blob/v2.1.0-rc.2/docs/decisions/structured-output-schema-isolation.md).
Those documents describe version 2 behavior, not the current release.
