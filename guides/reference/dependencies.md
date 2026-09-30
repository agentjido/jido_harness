# Dependencies and audit exceptions

Runtime dependencies support Harness execution, validation, and observation.
They must preserve the [architecture boundary](architecture.md).

## Runtime dependencies

| Dependency | Purpose |
| --- | --- |
| `erlexec` | Subprocesses, stdin, PTY, process groups, and signals |
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

## Native process startup

Harness requires erlexec `~> 2.5` for its PTY and process-group cleanup fixes.
The published 2.5.0 source can still fail a short non-PTY process on macOS
with `Cannot set effective group to 0: Operation not permitted`. The startup
regression test reproduced this after concurrent process starts and timeout
cleanup. A passing default unit suite does not rule out this failure.

A local erlexec patch was tested with 100 timeouts and 800 short processes.
It accepts a failed child group call only when the child already belongs to
the requested group. Tests also force a wrong group and require startup to
fail. The patch adds no retry. Additional failure logging confirmed that the
requested group was already set when the system call returned `EPERM`.
The cause of that system call failure and the older Codex failure in
[issue #71](https://github.com/agentjido/jido_harness/issues/71) remain open.

The patch is outside the Harness repository and Hex package. A package
consumer gets the published dependency, so macOS release verification
remains open. Do not replace pipe streams with a PTY, omit process-group
creation, or retry failed starts to make the test pass. Those changes alter
output or cancellation behavior.

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
audit, package, protocol, and lifecycle checks. Local native-process patches
do not address these findings.

## Dependency changes

Antigravity uses the pinned `@simonepri/refined-antigravity-acp@1.2.11`
Node package. Its supervisor converts a known server panic to `end_turn`.
The bundled module at `priv/acp/antigravity.mjs` changes that response to an
ACP error before Harness receives it. The installed Node package stays
unchanged. This version-specific correction is included in the Hex package
and release assets; it is separate from the private erlexec patch.

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
