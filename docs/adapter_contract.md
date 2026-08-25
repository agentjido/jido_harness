# Adapter contract reference

Every provider implements `Jido.Harness.Adapter`. The adapter describes how to
find the base CLI and how to start one ACP agent. It does not implement the ACP
protocol or the run lifecycle.

## Required callbacks

| Callback | Contract |
| --- | --- |
| `spec/0` | returns a validated `Jido.Harness.AdapterSpec` |
| `status/1` | returns normalized base-CLI readiness |

`install/2` is optional. `acp_env/2` is optional and can map provider
credentials into the ACP process environment.

`run/2` and `cancel/2` are not adapter callbacks in version 3. Harness opens an
ACP session, sends prompts through ExMCP, and owns cancellation.

## Adapter specification

`AdapterSpec` declares provider identity, one `ACPAgentSpec`, normalized request
options, and installation data. `ACPAgentSpec` declares the executable, argv,
source, package, maturity, supported options, and `SessionCapabilities`.

Declarations are enforced before Harness starts a run or session. An unknown
field, value, or provider option returns a validation error.

## ACP process boundary

Harness resolves the executable and starts it through its process manager.
Harness owns environment policy, process groups,
timeouts, signals, IDs, events, replay, retention, approvals, and lifecycle
state.

ExMCP owns ACP messages, validation, and protocol request correlation. Provider
adapters must not parse ACP JSON or correlate JSON-RPC IDs.

## Status and installation

`status/1` must not send a model prompt. `Jido.Harness.status/1` adds ACP-agent
readiness. `ProviderStatus.ready?/1` is true only when both the base CLI and ACP
executable are ready.

`Jido.Harness.install/2` installs the base CLI. It also installs the ACP package
when `ACPAgentSpec.source` is `:adapter`. Installation is an explicit caller
action and supports `dry_run: true`.

## Verification

An adapter change must pass deterministic ACP fixtures, lifecycle and cleanup
tests, affected live integration profiles, documentation compilation, static
analysis, and package build verification.
