# Jido.Harness usage rules

## Scope

- Use `jido_harness` as the single runtime for Amp, Claude, Codex, Gemini,
  OpenCode, Grok, and Z.AI.
- Treat `jido_shell` as unrelated; do not depend on it for harness execution.
- Keep run supervision and direct OS-process ownership inside Jido.Harness.

## Public API

- Start asynchronous work with `start/3` or `start_request/2`.
- Reattach by `run_id` using `info/1`, `stream/2`, `replay/2`, and `await/2`.
- Use `run_sync/3` only when blocking the caller is appropriate.
- Keep provider resume `session_id` separate from harness `run_id`.
- Put escape hatches under `provider_options`; unknown keys are errors.

## Processes

- Always pass `executable` and `argv`; do not interpolate shell commands.
- Use runtime and idle timeouts deliberately. Both default to `:infinity`.
- Use cursor replay for slow consumers instead of forwarding output to a
  long-lived mailbox.

## Security

- Do not put credentials in metadata, prompts, argv, telemetry, or failure
  artifacts.
- Pass credentials through the environment or the provider's cached login.
- Treat journals as sensitive even though their permissions are restricted.

## Testing

- Keep provider integration tests opt-in.
- Use deterministic fixture CLIs for PR tests and the 65-minute soak profile.
- Run strict live smoke tests for all seven providers before a release.
