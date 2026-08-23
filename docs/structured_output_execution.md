# Structured Output Execution Contract

This contract defines the planned provider-neutral request, ephemeral schema
lifecycle, isolation, Codex subscription execution, normalized result, and
failure behavior for finite schema-constrained Jido.Harness runs. It does not
claim that the capability is implemented or advertised.

## Request

A structured-output request shall contain:

- one registered provider selected explicitly by the caller;
- a bounded prompt and ordinary finite-run limits;
- one JSON Schema object with a stable caller-owned schema id;
- an explicit isolation profile;
- timeout, cancellation, output-byte, and event-retention ceilings; and
- provider options already advertised as compatible with structured output.

It shall reject schema paths, raw CLI arguments, shell text, credentials,
provider endpoints, unregistered adapters, session ids, resume ids, and
unknown or incompatible options.

## Schema admission and lifecycle

Before process creation, the harness shall validate that the schema is a JSON
object and enforce configured byte, nesting, property, enum, and combinator
ceilings. Admission shall reject unsupported keywords when the selected
provider cannot represent them exactly.

The admitted schema shall be serialized deterministically into a newly created
private harness directory. The directory and file shall use owner-only access,
shall not be consumer-selected, and shall not be reused across runs. Cleanup
shall execute after every terminal path, including start failure, caller exit,
timeout, cancellation, provider crash, malformed output, and validation
failure. Telemetry, errors, events, and results shall exclude schema bodies,
private paths, environment values, and credential locations.

## Isolation

The isolation profile shall explicitly resolve:

- an existing working directory or a harness-owned empty workspace;
- whether project instruction discovery is allowed;
- the exact writable workspace policy;
- a minimal environment inheritance policy compatible with the provider's
  installed CLI and cached authentication;
- network and sandbox options the adapter can represent; and
- whether provider configuration outside the request is admitted.

If the provider cannot honor a requested isolation property, the run shall be
rejected. The harness shall never report stronger isolation than the launched
argv and environment actually enforce.

## Codex subscription behavior

For provider `:codex`, the adapter shall use executable-plus-argv construction
for the reviewed Codex schema option and an ephemeral finite execution. The
Codex CLI resolves the operator's cached subscription authentication through
its ordinary mechanism; the harness shall not read, export, copy, log, or
translate credential material.

No direct OpenAI API, API key, Azure OpenAI, SDK call, provider substitution,
offline generator, or caller-owned Codex launcher is part of this contract.
Missing CLI, missing cached authentication, readiness failure, unsupported CLI
version, or provider outage shall return a typed failure.

## Result validation

The adapter shall identify exactly one terminal structured result under a hard
byte ceiling, decode JSON once, and validate it against the admitted schema.
Success shall include the schema id, provider, normalized terminal status, and
validated value without returning the private schema path.

The contract shall distinguish at least invalid request, unsupported schema,
unsupported capability, isolation unavailable, executable missing,
authentication unavailable, start failure, timeout, cancellation, provider
failure, output missing, output duplicate, output truncated, malformed JSON,
schema mismatch, and cleanup failure. Cleanup failure shall remain observable
without disclosing private paths.

## Ownership and compatibility

Jido.Harness owns request normalization, schema admission and staging,
provider translation, supervision, terminal output extraction, schema
validation, cleanup, normalized failures, and redacted telemetry. Consumers
own prompts, provider policy, domain schemas, post-schema semantic validation,
and decisions to accept or reject a result.

The initial contract is additive. Existing unstructured finite runs and
sessions retain their behavior. Structured-output capability is advertised
only by an exact released adapter version and shall fail closed across unknown
or incompatible Codex CLI versions.

## Acceptance scenarios

1. A valid bounded schema and compatible Codex installation produce one
   schema-valid result and leave no staged schema artifact.
2. Malformed, oversized, unsupported, missing, duplicate, or nonconformant
   output fails without best-effort repair.
3. Timeout and cancellation terminate the process group and remove the private
   schema directory.
4. An isolation request the adapter cannot enforce is rejected before launch.
5. Missing cached subscription authentication produces an authentication
   failure and never activates an API or provider fallback.
6. Concurrent structured runs cannot observe or reuse each other's schema,
   workspace, result, environment, or terminal state.
