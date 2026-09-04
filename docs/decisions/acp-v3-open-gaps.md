# ACP v3 review status

PR #64 contains the implementation for issue #61. The user approved an ExMCP
callback PR and use of that branch in Harness to resolve the original-message
gap. The Cowlib audit has a temporary, user-approved exception for this PR.
Harness keeps process and lifecycle ownership.

## ACP protocol message

The ExMCP Hex 1.2.0 callbacks omit the received JSON-RPC envelope. Merged
ExMCP PR #32 adds optional
`c:ExMCP.ACP.Client.Handler.handle_session_update/4` and
`c:ExMCP.ACP.Client.Handler.handle_permission_request/5` callbacks. Both `mix.exs`
and the lockfile pin the tested upstream merge commit. Consumers resolve their own
lockfiles, so the source declaration must also select that exact revision.
Replace this Git dependency with a supported Hex release after the upstream
change is released.

Upstream change: [merged ExMCP PR #32](https://github.com/azmaveth/ex_mcp/pull/32),
merge commit `d43ef8e3c996448f5bb75b83165b611b642360fd`.
Its tree matches the reviewed PR head. The functional callback commit is
`4b7b35b`; the later PR commit clarifies the ACP message boundary in its public
documentation.

The upstream merge commit is usable as a Git dependency. `mix hex.build`
rejects the temporary ExMCP Git dependency because Hex packages can depend
only on Hex packages.
The package check remains visible and will require an ExMCP release before
Harness can be packaged for Hex. No package or release was published.

ExMCP decodes and validates each message once and carries the received decoded
map through its existing handler queue. Unknown top-level and parameter fields
in that ACP message are retained, and the update queue byte limit counts the
retained context. Old callback modules continue to work. Only one callback
handles each event.

Harness stores this ACP-boundary map in `Event.raw` for updates and permission
requests. Normalized payloads and Harness IDs remain separate. A native ACP
provider writes this message. An ACP adapter constructs it from the provider's
native protocol, so native fields that the adapter does not map are not
available. Raw data is kept
in memory and is not persisted in the event journal. No second parser or
observer queue is added to Harness.
Run and turn results retain raw data from the bounded memory buffer.
Journal-backed replay and streams still omit it.

ExMCP tests cover unknown fields, malformed messages, session authority,
duplicate request IDs, callback ordering, queue limits, timeouts, and old
handlers. Harness tests cover fragmented input, results, replay, streaming,
turn and approval correlation, journal omission, and lifecycle cleanup.

Source: [ExMCP issue #31](https://github.com/azmaveth/ex_mcp/issues/31).

## Temporary Cowlib audit exception for PR #64

The user approved temporarily skipping the Cowlib audit requirement for PR #64.
The exception covers the three current Cowlib 2.19.0 advisories:
`EEF-CVE-2026-43969`, `EEF-CVE-2026-43971`, and `EEF-CVE-2026-43966`. These
findings no longer block this PR. All other required checks and the ACP message
context requirement still apply.

The audit continues to run and report its findings. A failed audit is recorded
as an accepted exception, not as a passing check. Recheck the exception when a
supported dependency fix becomes available. Removing HTTP dependencies is
follow-up work and is not required to complete this PR under the exception.

ExMCP 1.2.0 requires `plug_cowboy`, which brings Cowboy and Cowlib into Harness
even though Harness uses ACP over managed process streams. Updating the locked
ExMCP version does not remove these dependencies. The latest Cowlib Hex release
found during this work is 2.19.0. It remains affected by the three advisories
reported by `mix hex.audit`.

ExMCP PR #21 does not remove this dependency. Despite its title, the reviewed
head `5aead0f3f4399047647ba000a3586b95feb6d069` keeps `plug_cowboy` required and
makes only Bandit optional. The maintainer requires Cowboy in ExMCP 1.x to
preserve the legacy SSE handler. The maintainer identified optional HTTP
adapters as work for ExMCP 2.0. The PR also has merge conflicts and no reported
CI checks. Completing that PR as specified will not clear the Harness audit.

There are two possible paths. Keep supported ExMCP 1.x and wait for a fixed
Cowlib release, then update the lockfile and repeat the audit. Or prepare a
separate ExMCP 2.x change that makes all HTTP adapters optional, followed by a
Harness dependency migration. The second path needs a scope decision and a
supported upstream release. It is not a lockfile repair within this PR.

For an optional-adapter release, verify that an ACP-only Hex consumer compiles
and runs without Cowboy, Cowlib, or Ranch. Hosts that select an HTTP adapter
must retain their listener APIs, startup error handling, and JSON and SSE
behavior. Test both adapters over HTTP/1.1 and real TLS/HTTP2, including legacy
SSE process ownership, startup, duplicate listeners, and shutdown. Then update
Harness to the supported release and run `mix hex.audit` again.

A Cowlib update alone is not currently sufficient. Do not hide the advisories
with an ignore option, an unverified Git revision, or an aggregate CI result.
No HTTP-adapter change or dependency release is included in this Harness PR.

Sources: [Cowlib releases](https://hex.pm/packages/cowlib),
[ExMCP PR #21 reviewed dependency declaration](https://github.com/azmaveth/ex_mcp/blob/5aead0f3f4399047647ba000a3586b95feb6d069/mix.exs#L100),
[ExMCP maintainer's 1.x and 2.0 requirements](https://github.com/azmaveth/ex_mcp/pull/21#issuecomment-5383877790),
[cookie encoder advisory](https://cna.erlef.org/cves/CVE-2026-43969.html),
[link encoder advisory](https://cna.erlef.org/cves/CVE-2026-43971.html),
[structured header advisory](https://cna.erlef.org/cves/CVE-2026-43966.html).
