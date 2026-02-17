# Jido.Harness

Normalized Elixir protocol for CLI AI coding agents. Jido.Harness defines the
behaviours, schemas, and error types that provider adapter packages implement to
expose a unified interface for agents like Amp, Claude Code, Codex, and Gemini CLI.

## Installation

Add `jido_harness` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_harness, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Optional: configure provider modules explicitly
config :jido_harness, :providers, %{
  codex: Jido.Codex.Adapter,
  gemini: JidoGemini.Adapter
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

Full documentation is available at [https://hexdocs.pm/jido_harness](https://hexdocs.pm/jido_harness).
