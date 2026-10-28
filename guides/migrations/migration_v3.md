# Migrate to version 3

Version 3 is a full cutover. It has no compatibility layer for the V2 event
model, replay record format, direct CLI adapters, or alternate session
transports.

## Required versions

The `3.0.0-rc.1` branch uses the current Jido V3 source packages for `jido`,
`jido_action`, and `jido_signal`. During local development, use sibling path
dependencies from the same `proj_jido_core` checkout. Published applications
must use compatible Jido V3 releases from one source revision.

The development baseline for this cutover is:

| Package | Branch | Version | Revision |
| --- | --- | --- | --- |
| `jido_harness` | `feat/v3-native-primitives` | `3.0.0-rc.1` | based on `77465640a6e1` |
| `jido` | `release/v3` | `3.0.0-beta.2` | `233c37d1eee8` |
| `jido_action` | `release/v3` | `3.0.0-beta.22` | `177e7a4ce434` |
| `jido_signal` | `release/v3` | `3.0.0-beta.5` | `7b825f1d050a` |
| `runic` | `feat/workflow-scoped-fact-storage` | `0.1.0-alpha.12` | `2a8cffa9fa38` |

## Native primitives

| V2 | V3 |
| --- | --- |
| `Jido.Harness.Event` | Fixed `Jido.Signal` modules under `Jido.Harness.Signal.*` |
| `Jido.Harness.ProcessEvent` | `Jido.Harness.Signal.Process.*` |
| `result.events` | `result.signals` |
| event struct `sequence` | `Jido.Harness.Signal.sequence(signal)` |
| event struct `payload` | `signal.data["payload"]` |
| `:provider_event` | `:provider_message` |
| separate process replay gap | `jido.harness.replay.gap` for all resources |
| replay record format 1 | replay record format 2 with a native Signal map |
| `max_events` | `max_signals` |
| replay-store `retained_events` | `retained_signals` |

There are no aliases for the removed modules or fields.

## Jido Agents

Remove application-owned Harness wrappers when they only convert commands and
facts to custom Actions or Signals. Use:

- `Jido.Harness.Action.*` for typed command routes;
- `Jido.Harness.Directive.*` for post-commit effects;
- `Jido.Harness.Plugin` for workspace policy, ownership, idempotency, cursor
  recovery, and Signal delivery.

Keep the provider-specific Agent in the application. Do not put a Claude Code
Agent in the Harness package. See [Jido Agent integration](../jido_agents.md).

## ACP-only execution

All coding-agent runs and sessions use ACP. Remove `SessionRequest.transport`,
legacy session transport specs, direct provider command flags, and finite-run
`max_turns`. A finite run sends one ACP turn. Use a full Session for multi-turn
work.

Finite runs reject interactive approval mode. Use a Session when host code must
answer provider permission requests.

No built-in V3 ACP profile advertises structured output. Requests for it fail
before execution.

## Raw provider data

Raw decoded ACP envelopes are private adapter messages. They are not public
Signals and are not stored. Use normalized provider-message payloads or a
provider-specific adapter boundary.

## Verification

After migration:

1. Remove all references to `Jido.Harness.Event`, `ProcessEvent`, and
   `result.events`.
2. Delete old format-1 replay data or move it outside the V3 journal root.
3. Test one finite run and one two-turn Session with a real provider.
4. If you use a Jido Agent, test commit-before-I/O, duplicate command IDs,
   workspace escape denial, connection ownership, quiesce, and resume.
