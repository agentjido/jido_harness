# JidoHarness

Normalized Elixir protocol for CLI AI coding agents. JidoHarness defines the
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
# Configure a provider adapter
config :jido_harness, :providers, %{
  claude: MyApp.Adapters.Claude
}

# Run an agent
{:ok, events} = JidoHarness.run(:claude, "fix the bug", cwd: "/my/project")
```

## Documentation

Full documentation is available at [https://hexdocs.pm/jido_harness](https://hexdocs.pm/jido_harness).
