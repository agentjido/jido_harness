---
title: Embed coding agents in Jido V3 through Harness
type: implementation-plan
date: 2026-11-17
last_reviewed: 2026-11-17
artifact_contract: kata-plan/v1
artifact_readiness: implementation-ready
domain: software
execution: code
product_contract_source: direct-request
---

# Embed coding agents in Jido V3 through Harness

## Goal Capsule

- Add `Jido.Harness.Plugin` to `jido_harness`. A Jido V3 Agent can prompt Codex, Claude Code, or Amp, receive progress and results, and control a multi-turn conversation.
- Use the Harness session API and the Jido Chat plugin pattern. Applications can continue to install Harness by itself.
- This request authorizes planning. A later local implementation can use the fake ACP fixture. A live provider request or release requires separate authority.
- The next executor is a Harness maintainer. Start with U1 and prove both consumer build paths before adding plugin behavior.

## Product Contract

### Summary

A host application opts in by adding a compatible Jido V3 dependency and declaring `Jido.Harness.Plugin` on its Agent. The Agent sets the working directory and sends prompt and control Signals through its routes.

### Problem Frame

Harness runs coding agents through ACP and owns session state. The host currently has to connect the Harness lifecycle to its Jido Agent.

### Actors

- The host configures the Agent, admits user requests, and decides whether to grant a permission request.
- The Agent receives domain requests and handles Harness Signals. The selected provider runs in a Harness-managed ACP session.

### Requirements

| ID | Behavior |
| --- | --- |
| R1 | Install `jido_harness` without Jido. With compatible Jido V3, configure one provider in a flat `harness` block. |
| R2 | Route a prompt to the configured provider after the Jido turn commits. Reuse the live session for follow-ups in order. Keep separate Agent instances isolated. |
| R3 | Return correlated text progress and one terminal outcome per accepted turn while the activation remains available. |
| R4 | Interrupt the active turn by ID and let the host answer pending permission requests. Deny unanswered requests at the configured timeout. |
| R5 | Release the provider process on normal stop, Agent loss, or plugin runtime loss. Report failed work while the host is available. |
| R6 | Run the same prompt and follow-up contract through real Jido Agent wrappers for Codex, Claude Code, and Amp. |

### Key Flows

```elixir
defmodule CodexAgent do
  use Jido.Agent, name: "codex_agent", plugins: [Jido.Harness.Plugin]

  harness do
    provider :codex
    cwd env("REPO_AGENT_WORKSPACE")
    sandbox_mode :workspace_write
    approval_mode :prompt
    turn_runtime_timeout_ms 600_000
    approval_timeout_ms 30_000
    session_idle_timeout_ms 1_800_000
  end

  routes do
    route "repo.task.requested", MyApp.PreparePrompt
    route "jido.harness.command.*", Jido.Harness.Plugin.Execute
    route "jido.harness.error.command", MyApp.RecordCommandFailure
    route "jido.harness.turn.delta", MyApp.PublishProgress
    route "jido.harness.turn.finished", MyApp.RecordResult
    route "jido.harness.approval.requested", MyApp.RequestApproval
  end
end
```

A host Action emits a typed prompt command. A terminal Action returns a plugin directive. Core dispatches it after commit. The plugin submits the prompt and sends the normalized results back to the Agent.

### Acceptance Examples

- Two prompts to one Agent share provider context. A second instance of the same Agent module opens a separate conversation.
- A rejected Jido turn starts no ACP process. A slow provider startup leaves the Agent able to handle unrelated Signals.
- Interrupting a turn ends that turn. A healthy session accepts another prompt. An old approval reply cannot authorize a new request.
- Killing the plugin runtime while the provider is opening or running ends its provider process within the existing startup and shutdown limits.

### Success Criteria

The examples pass through public Agent routes with the fake ACP fixture. Each of the three live wrappers passes the same two-turn contract with its real provider. A clean app with Harness as its only dependency compiles and uses the existing standalone API.

### Scope Boundaries

The first slice covers text prompts, interrupt, and one-time permission decisions. The session belongs to the current plugin activation. Durable conversations, provider resume and fork, steering, and Chat SDK changes are deferred.

### Key Decisions

Keep the plugin in the `jido_harness` package. Jido is an optional dependency. Each Agent activation has one configured provider and at most one live conversation. The wrapper decides which provider to use at compile time.

### Rejected Alternatives

A named `session` inside `harness` would support routing to several conversations from one Agent. This slice has one provider and one conversation per activation, so the Agent instance already supplies that address. A host that needs several conversations can start several Agent instances.

### Dependencies

The local Git baseline is the Jido V3 revision used by Chat. Harness already has ACP profiles for all three providers and an ACP test fixture.

### Outstanding Questions

The minimum publishable Jido V3 version depends on the next compatible Hex release. The host supplies user identity and approval policy.

### Sources

- [Harness README](../../README.md)
- [Codex adapter](../../lib/jido_harness/adapters/codex.ex) · [Claude Code adapter](../../lib/jido_harness/adapters/claude.ex) · [Amp adapter](../../lib/jido_harness/adapters/amp.ex)
- [Chat plugin guide](../../../../jido_chat/jido_chat/guides/agent_plugin.md)

## Planning Contract

### Product Contract Preservation

The refined DSL keeps the post-commit route pattern and gives each activation one conversation. The live checks cover all three requested providers. The optional dependency keeps the plugin and standalone API in one package.

### Current System

Harness V3 RC supervises detached sessions. `Session.start/3` returns an ID before ACP is ready. `Session.follow_up/3` uses a bounded FIFO when the session is ready or busy. Harness owns approval timeout, interruption, event sequencing, and process cleanup. Jido Chat lowers a Spark section and dispatches an owned directive after commit.

### Target System

```text
Host Action -> typed command -> Execute -> commit -> plugin directive
  -> supervised runtime -> Harness Session -> configured ACP adapter
  -> normalized result Signals -> originating Agent activation
```

### Key Technical Decisions

- **KTD1 — One package with an optional dependency.** For the Git RC, declare `{:jido, github: "agentjido/jido", ref: "ec96da6015b4b1e5a1642d50651235d9d52808ec", optional: true}`. The host adds Jido directly. Use the same ref when the host also uses the current Chat V3 branch. Guard all plugin modules and their compile-time macros with a compile-time check for the required V3 extension API. Core Harness modules contain no Jido references. Keep Jido out of the Harness application start list. Use Spark directly only in the guarded plugin DSL. Add a direct optional Spark declaration only if the warnings-as-errors compile shows that it is needed. U1 owns this check. R1.
- **KTD2 — Use the Chat authoring pattern.** Add one Spark section with a schema for `provider`, `cwd`, and session options. Lower its fields into one config map through `Jido.Agent.Extension`. Use the same validated map for programmatic plugin configuration. Reject a declaration that uses both forms. Use a terminal `Execute` Action and an owned directive. Keep provider resolution and I/O in supervised runtime work after commit. R1, R2.
- **KTD3 — Give Harness an explicit process owner for plugin sessions.** Add an optional `owner: pid` start option. Strip it from runtime options before creating `SessionRequest`. Use the plugin runtime PID as the owner. Register the monitor inside the session worker before the ACP startup continuation. On owner loss, use the existing terminal lifecycle to deny pending approvals and stop the provider process. Ordinary sessions retain caller-independent ownership. R2, R5.
- **KTD4 — Relay a small set of typed Signals.** Use the existing Harness journal and turn results. Carry request and turn IDs across the Jido boundary. Bound relay work and apply Harness queue and retention limits. R3, R4.

### System Boundaries and Change Surface

**Declaration.** Require one declaration, a supported static provider, and a resolved working directory. Accept provider-supported sandbox and approval modes, finite timeouts, and the existing queue limits. Use the provider defaults when options are omitted. Claude Code and Amp wrappers omit the Codex-specific sandbox and approval options. Normalize against the Harness request schema after runtime value resolution. Validate provider capability at activation or before opening the session. Commands cannot change provider, directory, environment, or permission mode. Start the local plugin runtime during Agent activation and open ACP lazily.

| Signal suffix under `jido.harness` | Data |
| --- | --- |
| `command.prompt` | Host request ID and text |
| `command.interrupt` | Host request ID for this command and target Harness turn ID |
| `command.respond_approval` | Host request ID, plugin-issued approval ID, and `:approve` or `:deny` |
| `error.command` | Host command request ID and error code for rejection before admission or a failed control command |
| `turn.delta` | Host prompt request ID, Harness turn ID, sequence, and text |
| `turn.finished` | Host prompt request ID, Harness turn ID, terminal status, and bounded text or error code |
| `approval.requested` | Plugin-issued approval ID, safe summary, and optional turn and prompt IDs |

**Ordering and failure.** Enqueue work quickly in directive dispatch. Keep a bounded startup queue, then use the existing Harness FIFO. Install the ID mapping before the relay publishes events for a newly accepted turn. Keep a bounded request-ID cache per activation for in-flight and recent requests. On an ambiguous submission failure, report the uncertainty and leave retry to the host. On startup failure, resolve queued commands with a correlated failure. A later prompt can open a fresh session after the old session becomes terminal. A runtime replacement starts a new conversation.

**Event delivery.** Read bounded pages from `Session.replay_page/2`. Advance a cursor for the current session and coalesce adjacent text deltas before casting them. Handle replay gaps separately from provider errors. Reconcile known in-flight turns with retained status when possible. If required history has expired, report result unavailability once and discard late events for that turn. A finished Signal is best effort to the live activation. Persisted delivery receipts are outside this slice.

**Approval and access.** Treat plugin commands as internal application Signals. The host checks external identity and authority before emitting them. Match the approval ID to a pending request in the same live session and activation. Permit one response and reject expired or stale requests. Verify the provider supports prompted approvals before accepting a session configured for them. Harness applies the provider response and timeout. Relay only selected fields. Keep raw ACP frames, executable configuration, credentials, and resume tokens out of Signals and Agent state.

**Compatibility.** The plugin is additive for Harness sessions and requires the V3 contract. Harness already requires Zoi `~> 0.19.0`. The published Jido V3 beta.2 and V2.4.0 require Zoi `~> 0.18.11`. The Chat pin uses Zoi `~> 0.19.0`. The plan grants no compatibility claim for the published beta or V2. Local Core and Chat changes are unnecessary.

### Implementation Units

#### U1 — Prove optional dependency and compile the DSL

- Requirements R1. Initial unit. Change `mix.exs`, its lock, and the guarded plugin declaration.
- Use the Git baseline from KTD1. In one clean consumer, declare Harness alone and run a standalone call. In a second, add Jido and compile an Agent with the sample DSL. Also add Jido to the first consumer and confirm that a normal dependency resolution and compile make the plugin available. Check the resolved Zoi and Spark graph and confirm that Harness starts without starting Jido.
- Cover missing configuration, use of both DSL and programmatic config, unknown providers, invalid timeouts, unknown DSL options, and unresolved working directories. Reject provider options that the selected adapter does not support. U1 completes when both consumer builds and the DSL tests pass. A build that requires manual source edits or dependency overrides fails this gate.

#### U2 — Run and clean up one owned Harness session

- Requirements R2 and R5. Depends on U1 for the plugin runtime. Change `Session`, `SessionManager`, and `SessionWorker` for the optional owner, plus the plugin runtime and prompt directive.
- Test existing caller-independent sessions and managed sessions whose owner stops normally or dies during startup, an active turn, or idle. Check process and descendant cleanup. Test no provider call before commit and separate sessions for two Agent instances.
- U2 completes when the public prompt route queues work and ownership checks pass without credentials.

#### U3 — Return results and apply controls

- Requirements R2, R3, and R4. Depends on U2 for live session handles and turn correlation.
- Implement bounded event relay, terminal delivery, interrupt, and permission replies via Harness. Extend the fixture where a race cannot be reached with existing cases.
- Test fast completion, FIFO follow-ups with shared context, duplicate request IDs, queue overflow, relay gaps, provider failure, stale interrupt and approval IDs, approval expiry, and continuation after interrupt. U3 completes when these scenarios pass through the Agent routes.

#### U4 — Document and verify the consumer paths

- Requirements R1–R5. Depends on U3 for final behavior. Add the Agent plugin guide and an executable test example. Update Harness README and the ExDoc guide index.
- Verify the example with the fake ACP server and repeat the standalone and plugin consumer builds. Verify that the docs explain direct host opt-in, lifecycle, failure semantics, and the Git baseline. U4 completes with the repository and consumer gates below.

#### U5 — Verify Codex, Claude Code, and Amp through real Agent wrappers

- Requirement R6. Depends on U4 for the documented plugin contract and passing fixture gates.
- Add three executable Jido Agent modules with the same routes and shared Actions. Each declares one provider in its `harness` block. A shared driver starts each Agent, uses its public prompt route, collects its result Signals, and stops it. Make the wrappers available as examples and reuse them in the opt-in live test. Apply the existing `:integration` tag so the default suite excludes it.
- Run each wrapper with its installed ACP adapter and configured credentials in a separate temporary directory. Send a short prompt that supplies a unique test value and asks the provider to remember it without using tools. Send a second prompt that asks for that value without repeating it. Check correlated text progress, one successful terminal result per turn, and the correct value in the second result. Stop the Agent and confirm its session and provider process close.
- Use a two-prompt budget per provider for the initial run. Deny unexpected approval requests through the wrapper. Keep interrupt, approval expiry, and failure-path coverage in the deterministic suite because provider behavior and capability differ. Amp's ACP adapter is experimental. Report an adapter, account, or readiness failure by provider and keep that provider's gate open.
- Record the provider and ACP adapter versions, the two turn outcomes, and cleanup evidence for each wrapper. Omit credentials and raw provider traffic. U5 completes when all three real-provider runs pass.

### Work Graph

U1 → U2 → U3 → U4 → U5. The compatible Hex release is a separate gate for packaged plugin distribution. It does not block local work on the pinned Git baseline.

### Verification Contract

| Gate | Requirements | Evidence |
| --- | --- | --- |
| Consumer fixture | R1 | Harness-only, Harness plus Jido, and add-Jido-to-existing-build scenarios from U1 |
| ACP and lifecycle fixture | R2, R5 | Public Agent routes and process exit checks for each owner-loss scenario |
| Results and control fixture | R3, R4 | Route-level assertions for event correlation, queue limits, terminal status, interruption, and permissions |
| Repository checks | R1–R5 | Full default suite, quality gate, and docs build |
| Live Agent wrappers | R6 | Two successful routed turns and verified cleanup for each of Codex, Claude Code, and Amp |
| Hex distribution | R1 | Compatible published Core version, local package build, optional dependency metadata, and both clean consumers using the packaged artifacts |

Run the following from `jido_connect/jido_harness` after implementation. The default suite uses local fixtures.

```sh
mix test --no-cover test/jido_harness/acp_session_test.exs
mix test
mix quality
mix docs --warnings-as-errors
```

At the Hex gate, run `mix hex.build` locally and inspect the tarball metadata. Test a packaged build with the Jido dependency omitted, then with it installed. Before U5, check local provider and ACP readiness without sending a prompt.

```sh
mix jido_harness.check --providers codex,claude,amp --strict
```

With live-provider authority and credentials, run the new opt-in wrapper suite. U5 adds the test file below. It exercises the Agent routes with real ACP processes.

```sh
mix test --no-cover --include integration test/integration/agent_wrapper_live_test.exs
```

### Rollout and Recovery

Opt in per Agent declaration. To disable the plugin, stop the Agent and confirm its owned sessions terminate before restarting it without the declaration. Existing standalone sessions keep their original lifetime. Release a compatible Jido V3 version first, then update Harness to an optional Hex constraint and check both install paths before shipping the plugin on Hex. Chat can adopt it through application code.

### Risks and Assumptions

- Mix optional dependencies share the host's resolved dependency graph when installed. Verify dependency compilation in the consumer apps. A Git dependency is absent from Hex dependency metadata. [Mix dependency options](https://hexdocs.pm/mix/Mix.Tasks.Deps.html) · [Hex package dependencies](https://hexdocs.pm/hex/Mix.Tasks.Hex.Build.html#module-dependencies)
- A plugin runtime crash can cut off its relay before it reports a result. Session cleanup comes from the worker's owner monitor. No automatic prompt replay occurs on replacement.
- Starting ACP can block the session worker within the existing startup timeout. Test owner loss in this interval as well as after startup.
- Permission and cancellation behavior depends on the selected adapter and provider capability. The fixtures cover host policy and interruption. The live checks prove provider startup, routed prompts, conversation reuse, result delivery, and shutdown for each wrapper.

### Open Planning Decisions

- **Hex gate.** The Harness maintainer selects the minimum released V3 version after it passes U1 against Zoi 0.19 and the DSL contract. The oldest verified published version becomes the lower bound. The current beta.2 is incompatible. [Jido releases on Hex](https://hex.pm/packages/jido)
- **Host policy.** Each host chooses who can issue prompts and approve operations. The plugin validates scope and pending state after host admission.

### Definition of Done

U1–U5 pass on the Git baseline. The standalone consumer resolves and runs without Jido. The V3 consumer compiles the DSL and passes the prompt, follow-up, result, control, and cleanup checks. Each real wrapper passes the live gate. The guide identifies the supported baseline and how to run the wrappers. Hex distribution can proceed after the separate Hex gate passes.

### Planning Sources

- [Session API](../../lib/jido_harness/session.ex) · [Session worker](../../lib/jido_harness/session/worker.ex) · [Ownership guide](../../guides/ownership_timeouts_and_cancellation.md)
- [ACP fixtures](../../test/jido_harness/acp_session_test.exs) · [Harness package configuration](../../mix.exs) · [Testing guide](../../guides/testing.md) · [Provider profiles](../../guides/providers.md)
- [Chat plugin](../../../../jido_chat/jido_chat/lib/jido_chat/plugin.ex) · [Chat Core dependency](../../../../jido_chat/jido_chat/mix.exs)
- [Pinned Core manifest](https://github.com/agentjido/jido/blob/ec96da6015b4b1e5a1642d50651235d9d52808ec/mix.exs) · [Published V3 beta manifest](https://github.com/agentjido/jido/blob/v3.0.0-beta.2/mix.exs)

## Adapter Results

The canonical output is this Markdown plan.
