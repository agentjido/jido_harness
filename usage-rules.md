# Jido.Harness usage rules

## Scope

- Use `jido_harness` as the normalization and lifecycle runtime for Amp,
  Claude Code, Codex, Gemini CLI, Grok, Kimi Code, OpenCode, Pi, and Z.AI.
- Treat `jido_shell` as unrelated.
- Do not add provider SDK, Jido, Sprite, Splode, or generic subprocess-wrapper
  dependencies without changing the documented package boundary explicitly.

## Choose the public API

- Use `Jido.Harness.run/3` for a blocking one-shot request.
- Use `Jido.Harness.Run` for detached finite work and reattachment by `run_id`.
- Use `Jido.Harness.Session` for harness-owned multi-turn conversations.
- Use `Jido.Harness.Process` for direct structured executable-plus-argv
  processes.
- Keep `run_id`, `session_id`, `turn_id`, and `process_id` distinct from a
  provider's `provider_session_id`.

## Preserve normalization

- Accept and return Jido.Harness request, result, event, status, capability, and
  error types at the public boundary.
- Map provider records to canonical events only when semantics are preserved.
- Use `:provider_event` and `Event.raw` for output without a lossless canonical
  mapping.
- Keep provider-specific input under `provider_options`.
- Reject unsupported and unknown options; never silently ignore them.
- Do not fabricate unavailable usage, file changes, approvals, steering, or
  native-session behavior.

## Lifecycle

- Keep public resources owned by the Jido.Harness supervision tree rather than
  the starting or consuming caller.
- Treat await timeouts as waiter limits, not cancellation.
- Use cursor replay for reconnecting or slow consumers.
- Preserve exactly one terminal event per run, accepted turn, and session.
- Prune only terminal resources.

## Processes and security

- Always pass executable and argv separately; do not interpolate shell command
  strings.
- Bind adapter processes to their owning run or session transport.
- Target complete process groups during cancellation and shutdown.
- Keep credentials out of prompts, argv, metadata, telemetry, and journals.
- Pass credentials through provider cached login or the child environment.
- Treat journals as sensitive operational data even after redaction.
- Validate sandbox and approval support against the selected adapter rather
  than assuming provider equivalence.

## Testing

- Keep provider integration tests opt-in.
- Use deterministic fake CLIs for mapper, lifecycle, timeout, replay, and
  cleanup tests.
- Run `mix jido_harness.check --strict` for non-billable readiness.
- Use `mix jido_harness.chat PROVIDER` for one explicit live smoke request.
- Run affected live profiles before release; they may consume provider usage.
- Run `mix quality`, `mix test`, `mix docs`, and `mix hex.build` before release.
