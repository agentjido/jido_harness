# Jido Ecosystem Dependency Policy

This policy governs `jido_harness` and sibling provider/runtime packages during consolidation.

## Boundary Direction

For the Session Control surface, the dependency direction is:

- integration/composition packages may depend on `jido_harness`
- runtime kernels may implement `Jido.Harness.RuntimeDriver`
- external kernels must not own permanent Harness projection code

In practice that means:

- provider adapters remain a legacy compatibility surface under `:providers`
- Session Control runtime drivers register under `:runtime_drivers`
- kernel-private refs such as pids and monitor refs must stay out of the public IR

## Baseline Versions

- Elixir: `~> 1.18`
- Jido core line: `~> 2.0.0-rc.5`
- Zoi: `~> 0.17`
- Splode: `~> 0.3.0`

## Local Path And Git Fallbacks

Default dependency resolution for sibling Jido repos is:

- prefer sibling-relative `path:` dependencies during active local development
- otherwise fall back to exact pinned git `ref:` dependencies

This keeps local development convenient without making builds depend on live
branches or committed vendored `deps/` trees.

## Git/Branch Dependencies

Use a git/branch dependency only when one of the following is true:

- a required upstream fix is not yet published to Hex
- coordinated multi-repo migration requires same-day, unreleased changes
- temporary lockstep development is required for release-train validation

When using git/branch dependencies:

- document why in the PR/commit message
- prefer the narrowest affected package set
- remove as soon as a compatible Hex release exists
- do not use a floating branch as the default fallback when an exact `ref:`
  will do

## `override: true` Usage

`override: true` is allowed only for conflict resolution when:

- multiple transitive versions break compile/runtime contracts, or
- local path/git lockstep is required during migration.

For each override, keep a removal condition:

- specific package/version to upgrade to, and
- verification target (`mix deps.tree`, compile, test, quality).

## Removal Criteria

A temporary git/branch/override dependency should be removed once:

1. A compatible Hex release is available.
2. All dependent repos compile and test against the released version.
3. No contract regressions are observed in adapter contract tests and bot E2E smoke tests.
