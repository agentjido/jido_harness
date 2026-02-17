# Jido.Harness Usage Rules

## Scope
- `jido_harness` is a normalization layer for CLI coding-agent adapters.
- Keep it transport-agnostic and provider-neutral.
- Do not add provider-specific execution logic here.

## Public API
- Keep the facade in `Jido.Harness` small and stable.
- Validate external inputs through schema modules.
- Return normalized `%Jido.Harness.Event{}` streams.

## Error Handling
- Use `Jido.Harness.Error` helpers for external-facing failures.
- Preserve provider errors in `details` where possible.

## Testing
- Prefer deterministic adapter stubs for unit tests.
- Keep coverage above the configured threshold.
- Run `mix quality` before release.
