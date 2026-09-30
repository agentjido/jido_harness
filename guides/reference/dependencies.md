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

Remove an exception when a supported dependency update resolves it. Then run
audit, package, protocol, and lifecycle checks. Local native-process patches
do not address these findings.

## Dependency changes

A source override is appropriate only for a verified lifecycle or protocol
compatibility correction. Review shared dependency requirements before adding
an override in a host application.

For a provider-related dependency change, run fake-CLI protocol and cleanup
checks, the full unit suite, static analysis, documentation, and package
builds. Run affected live profiles as described in [Testing](../testing.md).

Changes to ExMCP's required HTTP dependencies need a compatible ExMCP release
and verification of the ACP APIs that Harness uses.
