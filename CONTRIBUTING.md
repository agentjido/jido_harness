# Contributing to Jido.Harness

## Set up

Use Elixir 1.19 or a compatible later version and its supported Erlang/OTP
version. Pull-request CI checks Elixir 1.19 with OTP 28 and Elixir 1.20 with
OTP 29.

```console
git clone https://github.com/agentjido/jido_harness.git
cd jido_harness
mix setup
```

Local unit tests use fake CLIs. They do not need provider credentials.

## Find the right files

| Path | Contents |
| --- | --- |
| `lib/jido_harness.ex` | Public facade |
| `lib/jido_harness/` | Adapters, public types, and resource lifecycle |
| `lib/mix/tasks/` | Provider readiness and one-request smoke tasks |
| `config/config.exs` | Repository logging, commit checks, and release tools |
| `guides/` | Getting started, workflows, shared concepts, and operations |
| `guides/reference/` | Configuration, events, telemetry, architecture, and dependencies |
| `guides/migrations/` | Upgrade instructions for the current release |
| `guides/livebooks/` | Runnable notebooks |
| `guides/recipes/` | Tested application examples and their instructions |
| `test/jido_harness/`, `test/mix/` | Unit and fake-CLI tests |
| `test/integration/` | Optional live provider and long process tests |
| `test/support/` | Shared test modules and executable fixtures |
| `test/support/modules/` | Modules compiled with the unit suite |
| `test/support/fixtures/escript/` | A small Mix project that tests native-helper packaging |
| `doc/` | Generated API documentation; ignored by Git |

Keep package boundaries clear. Harness owns execution and resource lifetime.
ExMCP owns ACP protocol handling. Application policy and service integrations
belong outside Harness.

## Run checks

```console
mix test
mix quality
mix docs --warnings-as-errors
mix hex.build
```

`mix quality` checks formatting, compiler warnings, Credo, Dialyzer, and Doctor.
Doctor checks all modules. Public APIs must have useful docs and typespecs.
Internal modules use `@moduledoc false` to stay out of the public API docs;
they do not need entries in an ignore list.

The escript test builds the fixture in `test/support/fixtures/escript/` and
checks native-helper extraction in a separate VM. The approval-policy tests
load the recipe in `guides/recipes/policy_job.exs`. Keep these checks when you
change packaging or session behavior.

The default suite currently reports about 72% line coverage. `coveralls.json`
enforces a 70% minimum through ExCoveralls, with no file exclusions. This
prevents a large drop in existing coverage. The stable release target is 90%:
raise the minimum and meet that target before a stable release.
For a focused test run, use `mix test --no-cover test/path_test.exs`; a subset
does not measure full-suite coverage.

## Change documentation

Put documentation under `guides/`. Put notebooks under `guides/livebooks/` and
tested application recipes under `guides/recipes/`. Link related pages with
relative paths.

Keep one guide for each workflow or shared contract. Link to reference pages
instead of repeating their tables. Keep current release instructions in the
published guides; link to an immutable Git tag for historical contracts.

Add each published guide to the appropriate `@guide_groups` entry in `mix.exs`.
That list defines both ExDoc extras and their navigation groups. Do not create
a second list of guide paths. Root project documents have a separate short
list in `@project_docs`.

Build docs with `--warnings-as-errors` after moves or API changes. Check links
in source files as well as in generated HTML. Run Livebooks from their saved
locations so that their local dependency paths resolve correctly.

## Live provider checks

Live tests need installed CLIs, ACP entry points, and credentials. They can
consume provider usage. They are excluded from the default unit suite.

Use the [testing guide](guides/testing.md) to select a provider and profile.
The manually started live-integration workflow installs both provider
components and runs the same ExUnit contracts.

## Prepare a release

Run the four checks above and the affected live provider profiles. Review the
[dependency audit exceptions](guides/reference/dependencies.md#audit-exceptions) and
[current provider limits](guides/providers.md). A local patch does not fix the
published dependency for package consumers.

The Hex package contains runtime source and documentation. Repository
configuration, tests, and test fixtures stay in the source repository.
Inspect `mix hex.build` output before publication.

Do not edit `CHANGELOG.md` by hand. Release automation creates release notes
from Git history. Use Conventional Commits, for example:

```text
fix(session): close the process after cancellation
docs: clarify provider setup
chore: organize release files
```

## Pull requests and license

Create a branch, make the change, and run the relevant checks before you submit
a pull request. Explain the user-visible change and the evidence from tests.
Contributions use the Apache-2.0 license in [LICENSE](LICENSE).
