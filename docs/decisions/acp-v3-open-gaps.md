# ACP v3 merge blockers

PR #64 contains the implementation for issue #61. It must remain a draft until
the following dependency gaps are resolved. Harness keeps process and lifecycle
ownership in both cases.

## Original protocol message

ExMCP 1.2.0 passes only `(session_id, update)` to
`c:ExMCP.ACP.Client.Handler.handle_session_update/3`. Permission callbacks receive
the tool call and options, but not the original JSON-RPC envelope. Unknown
fields in that envelope are therefore unavailable to Harness event mapping.

Harness now keeps the complete received update map in `Event.raw`, including
fields that are absent from the normalized payload. This is an improvement,
but it does not restore the full original protocol message. Raw data is kept
in memory and is not persisted in the event journal.

The required upstream change is an optional callback with original-message
context for session updates and permission requests. Existing callbacks must
remain compatible. ExMCP must decode and validate each message once, then carry
the original decoded envelope through its existing handler queue. The context
must retain unknown top-level and parameter fields. It must not use a second,
unbounded observer queue or change request IDs and approval semantics.

Upstream tests must cover unknown fields, fragmented input, malformed messages,
duplicate request IDs, handler ordering, queue limits, and old callback modules.
Harness must then test that each normalized event has the correct original
message and that journal redaction and lifecycle behavior are unchanged. Do not
construct a partial envelope and describe it as the original message.

Source: [ExMCP 1.2.0 handler contract](https://github.com/azmaveth/ex_mcp/blob/v1.2.0/lib/ex_mcp/acp/client/handler.ex).

## Cowlib audit failure

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
No upstream change or dependency release is included in this Harness PR.

Sources: [Cowlib releases](https://hex.pm/packages/cowlib),
[ExMCP PR #21 reviewed dependency declaration](https://github.com/azmaveth/ex_mcp/blob/5aead0f3f4399047647ba000a3586b95feb6d069/mix.exs#L100),
[ExMCP maintainer's 1.x and 2.0 requirements](https://github.com/azmaveth/ex_mcp/pull/21#issuecomment-5383877790),
[cookie encoder advisory](https://cna.erlef.org/cves/CVE-2026-43969.html),
[link encoder advisory](https://cna.erlef.org/cves/CVE-2026-43971.html),
[structured header advisory](https://cna.erlef.org/cves/CVE-2026-43966.html).
