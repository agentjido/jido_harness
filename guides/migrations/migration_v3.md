# Migrate to version 3

Version 3 is a full cutover. It has no compatibility layer for the V2 event
model, replay record format, direct CLI adapters, or alternate session
transports.

## Required versions

Version 3 uses `jido_signal ~> 3.0.0-beta.5` for its public Signal types. It
does not require the `jido` Agent runtime, `jido_action`, or `runic`.

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
