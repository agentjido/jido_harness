# Jido.Harness

Normalized Elixir protocol for CLI AI coding agents. Jido.Harness defines the
behaviours, schemas, and error types that provider adapter packages implement to
expose a unified interface for agents like Amp, Claude Code, Codex, and Gemini CLI.

## Installation

Add `jido_harness` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_harness, github: "agentjido/jido_harness", branch: "main", override: true}
  ]
end
```

The adapter packages are currently being aligned as a GitHub-based repo set, so sibling adapters should use GitHub dependencies in this phase as well.

## Usage

```elixir
# Optional: configure provider modules explicitly
config :jido_harness, :providers, %{
  codex: Jido.Codex.Adapter,
  gemini: Jido.Gemini.Adapter
}

# Optional: set a default provider
config :jido_harness, :default_provider, :codex

# Run with explicit provider
{:ok, events} = Jido.Harness.run(:codex, "fix the bug", cwd: "/my/project")

# Or run through the default provider
{:ok, events} = Jido.Harness.run("fix the bug", cwd: "/my/project")
```

## What It Wraps

`Jido.Harness` can resolve providers from:
- explicit app config (`config :jido_harness, :providers, %{...}`)
- runtime auto-discovery of known module candidates for:
  - `:codex`
  - `:amp`
  - `:claude`
  - `:gemini`
  - `:opencode`

Auto-discovery is non-invasive: modules are used only if they are loaded and expose a supported run API.

## Public Facade

Core functions:

```elixir
Jido.Harness.providers()
Jido.Harness.default_provider()

Jido.Harness.run(:codex, "prompt", cwd: "/repo")
Jido.Harness.run("prompt", cwd: "/repo")

request = Jido.Harness.RunRequest.new!(%{prompt: "prompt"})
Jido.Harness.run_request(:codex, request, transport: :exec)
Jido.Harness.run_request(request)

Jido.Harness.capabilities(:codex)
Jido.Harness.cancel(:codex, "session_id")
```

## Documentation

- [`docs/adapter_contract.md`](docs/adapter_contract.md) for the shared adapter checklist
- [`docs/dependency_policy.md`](docs/dependency_policy.md) for the current dependency policy
- `mix docs` to build local package docs during this GitHub-dependency phase

## Package Purpose

`jido_harness` is the provider-neutral contract and runtime layer for CLI coding agents. It normalizes adapter interfaces and runtime preflight/bootstrap behavior.

## Testing Paths

- Unit/runtime tests: `mix test`
- Full quality gate: `mix quality`
- Registry/runtime diagnostics: `Jido.Harness.Registry.diagnostics/0` in `iex -S mix`
