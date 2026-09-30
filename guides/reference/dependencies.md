# Dependencies and audit exceptions

Runtime dependencies support Harness execution, validation, and observation.
They must preserve the [architecture boundary](architecture.md).

## Runtime dependencies

| Dependency | Purpose |
| --- | --- |
| `ex_mcp` | ACP messages, protocol validation, and request correlation |
| `telemetry` | Runtime observation |
| `zoi` | Validation and construction of public structs |
| `jason` | Journal encoding and local data |

Harness requires ExMCP `~> 1.3` for ACP message-context callbacks. The current
lockfile selects ExMCP 1.5.0. Zoi accepts the 0.17 and 0.18 lines so consumers
can share a validation runtime with Jido.

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

## Audit exceptions

The current lockfile selects Cowlib 2.20.0 through ExMCP's required Cowboy
and `plug_cowboy` dependencies. Harness uses ACP over managed process streams
and does not start an HTTP listener itself.

`mix.exs` contains two explicit audit exceptions:

| Advisory | Record |
| --- | --- |
| `EEF-CVE-2026-43966` | [Structured HTTP header encoder](https://cna.erlef.org/cves/CVE-2026-43966.html) |
| `EEF-CVE-2026-43969` | [Cookie request header encoder](https://cna.erlef.org/cves/CVE-2026-43969.html) |

Run the audit before release:

```console
mix hex.audit
```

The listed IDs are excluded from audit failure. Other advisories can fail the
check. A passing audit does not mean these exceptions have been resolved.
The current exceptions require review before a production release.

The September 2026 review found no calls to the affected header or cookie
encoders in the Harness ACP path. ExMCP's application starts no HTTP listener.
These are scope limits, not fixes to Cowlib. The
[structured-header advisory](https://cna.erlef.org/cves/CVE-2026-43966.html)
requires validation of encoder input. It also identifies Cowboy 2.16 and
later with `invalid_response_headers: :error_terminate` as a server-side
mitigation. The locked Cowboy 2.19.0 keeps that default.
The [cookie advisory](https://cna.erlef.org/cves/CVE-2026-43969.html)
requires valid cookie names and values before encoding. Host applications
that use these HTTP functions must check their own input paths and options.

Remove an exception when a supported dependency update resolves it. Then run
audit, package, protocol, and lifecycle checks. The bundled native process correction
does not address these findings.

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

Changes to ExMCP's required HTTP dependencies need a compatible ExMCP release
and verification of the ACP APIs that Harness uses.
