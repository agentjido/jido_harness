# Jido Harness Telemetry Contract

`Jido.Harness.Observe` is the only supported telemetry emission boundary for harness runtime flows.

## Canonical Namespaces

| Namespace | Use |
| --- | --- |
| `[:jido, :harness, :workspace, ...]` | Workspace/session lifecycle events |
| `[:jido, :harness, :runtime, ...]` | Shared runtime validation/bootstrapping |
| `[:jido, :harness, :provider, ...]` | Provider-specific runtime and stream events |

## Required Metadata

Every emitted event must contain these keys (set to `nil` when unavailable):

- `:request_id`
- `:run_id`
- `:provider`
- `:owner`
- `:repo`
- `:issue_number`
- `:session_id`

## Sensitive Data Redaction

`Jido.Harness.Observe.sanitize_sensitive/1` recursively redacts key/value pairs for common secret names:

- exact keys like `token`, `api_key`, `client_secret`, `password`
- keys containing `secret_`
- keys ending with `_token`, `_key`, `_secret`, `_password`

Redacted values are always replaced with `"[REDACTED]"`.
