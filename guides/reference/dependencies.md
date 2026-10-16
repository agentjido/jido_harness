# Dependencies and audit

Runtime dependencies support Harness execution, validation, and observation.
They must preserve the [architecture boundary](architecture.md).

## Runtime dependencies

| Dependency | Purpose |
| --- | --- |
| `arbor_acp` | ACP messages, protocol validation, and request correlation |
| `telemetry` | Runtime observation |
| `zoi` | Validation and construction of public structs |
| `jason` | Journal encoding and local data |

Harness requires `arbor_acp ~> 1.0.0-rc.1` from Hex. It provides the
`Arbor.ACP.Client`, handler callbacks, and transport contract. Its required
`arbor_rpc` dependency supplies shared protocol primitives. Harness does not
need `arbor_acp_adapters` or `arbor_mcp`; it retains its own provider adapters
and managed-process transport. Zoi uses the 0.18 line.

`arbor_rpc` builds its own native subprocess helper on macOS and Linux and
requires a C17 compiler. Harness continues to use its bundled erlexec engine
for managed processes; this migration does not select Arbor's process backend.

Harness does not require provider SDKs, `jido`, `jido_shell`, Sprites, or
Splode. Provider routing, workspace provisioning, retries, and durable job
storage belong to the host application.

## Bundled native process engine

Harness includes a private copy of erlexec 2.5.0 in `vendor/erlexec/`. It owns
subprocess pipes, PTY handling, process groups, signals, and cleanup. The Hex
package no longer depends on the external erlexec application.

The source is pinned to upstream commit
`d5c6d4ec2b5dd899c496e78c0aaa393651f80fdc`. `UPSTREAM.json` records the source
hashes and local patches. The original BSD license is included. Private
Erlang module and process names allow another application to use erlexec in
the same VM without a conflict.

A Mix compiler builds the C++17 helper from this source. Builds require make,
a C++17 compiler, and the Erlang `erl_interface` headers and library. Releases
include the built helper. Escripts use the [bootstrap function](../escripts.md)
to extract it before Harness starts.

The bundled source includes the process-group startup correction submitted
in [erlexec PR #210](https://github.com/saleyn/erlexec/pull/210). If a child
group assignment fails, it continues only when the requested group is already
set. A wrong group still causes startup to fail. There is no retry.

CI checks both outcomes with forced native errors on macOS and Linux. It also
checks concurrent startup, timeout cleanup, PTY behavior, and packaged helper
execution. The correction is part of the package; consumers need no private
patch installer.

The older Codex observation in
[issue #71](https://github.com/agentjido/jido_harness/issues/71) had no captured
stderr. Its cause remains unproven. Harness retains bounded process stderr
and lifecycle events for any recurrence.

## Dependency audit

The ACP-only dependency removes the former MCP HTTP dependency tree, including
Cowboy, Cowlib, Plug and JOSE. The Cowlib audit exceptions have been removed.
Run `mix hex.audit` before release and review any new advisories.

## Dependency changes

Antigravity uses the pinned `@simonepri/refined-antigravity-acp@1.2.11`
Node package. Its supervisor converts a known server panic to `end_turn`.
The bundled module at `priv/acp/antigravity.mjs` changes that response to an
ACP error before Harness receives it. The installed Node package stays
unchanged. This version-specific correction is included in the Hex package
and release assets alongside the native process helper.

The Antigravity CI job runs the actual pinned wrapper against a fake backend.
It checks a failed turn and recovery on the next requested turn without
credentials, model requests, or automatic task retries.

A source override is appropriate only for a verified lifecycle or protocol
compatibility correction. Review shared dependency requirements before adding
an override in a host application.

For a provider-related dependency change, run fake-CLI protocol and cleanup
checks, the full unit suite, static analysis, documentation, and package
builds. Run affected live profiles as described in [Testing](../testing.md).

Changes to Arbor ACP require verification of the ACP APIs that Harness uses.
