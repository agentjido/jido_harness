defmodule JidoHarness do
  @moduledoc """
  Normalized Elixir protocol for CLI AI coding agents.

  JidoHarness provides a unified facade for running CLI coding agents (Amp, Claude Code,
  Codex, Gemini CLI, etc.) through a consistent API. Provider adapter packages implement
  the `JidoHarness.Adapter` behaviour to normalize each agent's CLI interface.

  ## Usage

      {:ok, events} = JidoHarness.run(:claude, "fix the bug", cwd: "/my/project")

  """

  alias JidoHarness.{Registry, RunRequest}

  @doc """
  Runs a CLI coding agent with the given prompt.

  Looks up the adapter for `provider` from the registry and delegates to its `run/2` callback.

  ## Parameters

    * `provider` - Atom identifying the provider (e.g. `:claude`, `:amp`, `:codex`)
    * `prompt` - The prompt string to send to the agent
    * `opts` - Keyword list of options passed to `RunRequest.new/1`

  ## Returns

    * `{:ok, Enumerable.t()}` - A stream of `JidoHarness.Event` structs
    * `{:error, term()}` - On failure
  """
  @spec run(atom(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run(provider, prompt, opts \\ []) do
    with {:ok, adapter} <- Registry.lookup(provider),
         {:ok, request} <- RunRequest.new(Map.new([{:prompt, prompt} | opts])) do
      adapter.run(request, opts)
    end
  end
end
