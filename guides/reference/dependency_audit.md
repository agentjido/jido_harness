# Dependency audit exceptions

This checkout has two explicit Cowlib advisory exceptions in `mix.exs`:

- `EEF-CVE-2026-43966`
- `EEF-CVE-2026-43969`

The lockfile selects ExMCP 1.5.0 and Cowlib 2.20.0. Cowlib enters through Cowboy
and `plug_cowboy`, which ExMCP requires. Harness uses ExMCP for ACP over managed
process streams. It does not start an HTTP listener itself.

The old `EEF-CVE-2026-43971` exception was removed because its
[affected range ends before Cowlib 2.20.0](https://cna.erlef.org/cves/CVE-2026-43971.html).
The other two exceptions remain and need release review.

## Effect on checks

Hex audit still runs. The listed IDs are excluded from audit failure; other
advisories can fail the check. A passing aggregate CI result does not mean that
these exceptions have been removed.

```console
mix hex.audit
```

Review the exceptions before a production release. Remove the IDs when a
supported dependency update resolves them, then run the audit and the package,
protocol, and lifecycle checks again. A local process patch does not address
these advisories.

## Dependency boundary

ExMCP 1.3 supplies ACP message-context callbacks used by Harness. Replacing it
with an unverified Git revision or removing its required HTTP dependencies is
not a package cleanup. Such a change needs a supported dependency release and
separate compatibility tests.

See the [dependency policy](dependency_policy.md) and
[ExMCP ACP boundary](../decisions/exmcp-acp-boundary.md). The original advisory
records describe the affected behavior:

- [Structured header advisory](https://cna.erlef.org/cves/CVE-2026-43966.html).
- [Cookie encoder advisory](https://cna.erlef.org/cves/CVE-2026-43969.html).
- [Link encoder advisory](https://cna.erlef.org/cves/CVE-2026-43971.html).
