# Structured Output Uses Harness-Owned Ephemeral Schema Isolation

Status: accepted on 2026-08-23.

This decision establishes the generic Jido.Harness authority for validating a
caller-supplied output schema, staging it privately for a finite CLI run, and
returning only schema-conformant structured output. It authorizes planning and
contract work, not implementation or release availability.

## Context

Applications need coding-agent CLIs to return bounded machine-readable results
without teaching each consumer provider-specific arguments, temporary-file
lifecycle, output extraction, cancellation, or redaction. Codex supports a
schema-constrained execution path while using an operator's existing cached
subscription authentication. Jido.Harness already owns executable-plus-argv
construction, supervised finite runs, provider normalization, timeouts, and
process-group cancellation.

## Decision

1. Jido.Harness owns a provider-neutral structured-output request contract and
   provider-specific translation. The caller supplies JSON Schema data and
   bounds, never a schema path, shell fragment, raw provider argument, or
   credential.
2. The harness validates accepted schema shape and byte/depth/property limits
   before process creation. Unsupported schema features and provider
   capabilities fail before the CLI is started.
3. Schema files live in a harness-created private directory, use restrictive
   permissions, are addressed only by executable argv, and are removed after
   success, failure, timeout, cancellation, or caller exit. Schema bodies and
   private paths are excluded from telemetry and normalized errors.
4. Structured runs are finite and ephemeral. A request cannot attach to or
   resume a prior provider session, inherit another run's schema, or reuse a
   previous structured result. Process supervision and cancellation retain the
   existing Jido.Harness ownership rules.
5. An isolation profile explicitly controls working directory, environment
   inheritance, writable paths, provider configuration, and ambient project
   instruction discovery. The harness rejects incompatible provider options
   rather than weakening isolation silently.
6. The Codex adapter maps the validated schema to the reviewed Codex CLI
   interface and uses the CLI's existing cached subscription authentication.
   Jido.Harness neither reads nor copies credential material and introduces no
   OpenAI API, API key, Azure OpenAI, SDK, or alternate execution fallback.
7. Successful provider termination is not structured-output success. The
   harness locates the single terminal result, enforces byte limits, parses
   JSON once, validates it against the accepted schema, and returns a typed
   normalized result. Missing, duplicate, malformed, truncated, or invalid
   output is a typed failure with no best-effort repair.
8. Callers own prompts, product policy, provider selection, accepted schema
   meaning, and validation beyond schema conformance. Jido.Harness owns no HR,
   evidence, search, answer, classification, or corpus semantics and does not
   route automatically to another provider.
9. Readiness checks remain non-billable and distinct from opt-in live smokes.
   Capability discovery must not advertise structured output until the exact
   adapter behavior is implemented, tested, and released.

## Consequences

- Consumers share one reviewed lifecycle and failure contract instead of
  implementing private Codex wrappers.
- Cached subscription authentication stays in the Codex CLI boundary.
- Schema conformance reduces output ambiguity without granting model output
  product or authorization meaning.

## Rejected alternatives

### Let callers create schema files

Rejected because callers would duplicate sensitive path, permission, cleanup,
and cancellation behavior.

### Treat valid JSON as schema-conformant

Rejected because syntactic parsing does not enforce required fields, bounds,
or additional-property policy.

### Fall back to an API or another provider

Rejected because a provider outage or incompatibility must remain visible and
must not change authentication, billing, privacy, or model semantics.

## Contract

The normative planning contract is
[`structured_output_execution.md`](../structured_output_execution.md).
