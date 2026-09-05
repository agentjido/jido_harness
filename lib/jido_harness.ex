defmodule Jido.Harness do
  @moduledoc """
  Normalized, supervised runtime for coding-agent CLIs.

  Jido.Harness runs coding-agent CLIs through one ACP interface and translates
  ACP activity into validated Elixir requests, ordered events, terminal
  results, readiness information, capabilities, and errors. Built-in adapters
  cover Amp, Claude Code, Codex, Gemini CLI, Grok, Kimi Code, OpenCode, Pi, and
  Z.AI.

  `run/3` is the simplest entry point. It starts one supervised finite run,
  waits for completion, and returns a `Jido.Harness.RunResult`.

      {:ok, %Jido.Harness.RunResult{status: :completed} = result} =
        Jido.Harness.run(:codex, "Reply with exactly: ready",
          cwd: File.cwd!(),
          await_timeout: 300_000
        )

  Use the lifecycle modules for explicit resource control:

  * `Jido.Harness.Run` manages detached finite runs.
  * `Jido.Harness.Session` owns multi-turn conversations.
  * `Jido.Harness.Process` manages structured executable-and-argv processes.

  These resources belong to the application supervision tree rather than the
  caller that starts, streams, or awaits them. Stable harness IDs are distinct
  from provider-owned resume identifiers.

  Shared provider semantics have stable normalized fields. Optional behavior is
  declared through capability structs, and provider-specific escape hatches are
  explicit. See the [overview](overview.html) and
  [normalization guide](normalization_and_data_model.html).
  """

  alias Jido.Harness.{AdapterSpec, Error, ProviderStatus, Registry, Run, RunRequest, RunResult, Validation}

  @version "3.0.0-rc.1"

  @type provider :: atom()
  @type request :: String.t() | map() | keyword() | RunRequest.t()
  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "Returns the package version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns all built-in and configured adapter specs, ordered by provider name."
  @spec providers() :: [AdapterSpec.t()]
  def providers do
    Registry.providers()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn provider ->
      case Registry.spec(provider) do
        {:ok, spec} -> [spec]
        _error -> []
      end
    end)
  end

  @doc "Returns the configured default provider, if one is set."
  @spec default_provider() :: provider() | nil
  def default_provider, do: Registry.default_provider()

  @doc """
  Runs a request to completion using its provider or the configured default.

  The request may be a prompt, a map, a keyword list, or a
  `Jido.Harness.RunRequest`. Pass `:await_timeout` to bound only the caller's
  wait; a wait timeout does not cancel the supervised run.
  """
  @spec run(request()) :: result(RunResult.t())
  def run(request), do: run(request, [])

  @doc """
  Runs a request to completion with an explicit provider.

  This two-argument form also accepts a providerless request followed by its
  options. An atom in the first position is always treated as a provider.
  """
  @spec run(provider() | request(), request() | keyword()) :: result(RunResult.t())
  def run(provider, request) when is_atom(provider), do: run(provider, request, [])
  def run(request, options), do: execute(fn run_options -> Run.start(request, run_options) end, options)

  @doc "Runs a request to completion with an explicit provider and options."
  @spec run(provider(), request(), keyword()) :: result(RunResult.t())
  def run(provider, request, options) do
    execute(fn run_options -> Run.start(provider, request, run_options) end, options)
  end

  @doc "Returns normalized installation, compatibility, authentication, and ACP session status."
  @spec status(provider()) :: result(ProviderStatus.t())
  def status(provider) do
    with {:ok, adapter} <- Registry.lookup(provider),
         {:ok, spec} <- Registry.spec(provider),
         config = Registry.provider_config(provider),
         {:ok, status} <- adapter.status(config) do
      acp_agent = spec.acp_agent
      acp_path = config[:acp_path] || config["acp_path"] || (acp_agent && acp_agent.executable)
      session_ready = not is_nil(acp_agent) and executable_available?(acp_path)
      {:ok, %{status | acp_agent: acp_agent, session_ready: session_ready}}
    end
  end

  @doc "Performs or previews the provider CLI and required ACP adapter installation recipes."
  @spec install(provider(), keyword()) :: result(term())
  def install(provider, options \\ []) do
    with {:ok, adapter} <- Registry.lookup(provider),
         {:ok, spec} <- Registry.spec(provider),
         {:ok, cli_result} <- install_cli(provider, adapter, options),
         {:ok, acp_result} <- install_acp_agent(provider, spec.acp_agent, options) do
      case acp_result do
        nil -> {:ok, cli_result}
        result -> {:ok, %{provider: provider, status: result.status, components: %{cli: cli_result, acp: result}}}
      end
    end
  end

  defp install_cli(provider, adapter, options) do
    if function_exported?(adapter, :install, 2) do
      adapter.install(Registry.provider_config(provider), options)
    else
      {:error, Error.new(:provider, "provider does not expose an installation recipe", provider: provider)}
    end
  end

  defp install_acp_agent(_provider, %Jido.Harness.ACPAgentSpec{source: :native}, _options), do: {:ok, nil}

  defp install_acp_agent(provider, %Jido.Harness.ACPAgentSpec{source: :adapter, package: package}, options),
    do: Jido.Harness.Adapters.Helpers.install_npm(provider, package, options)

  defp install_acp_agent(_provider, nil, _options), do: {:ok, nil}

  defp execute(start_run, options) do
    with {:ok, options} <- Validation.keyword_options(options),
         await_timeout = Keyword.get(options, :await_timeout, :infinity),
         :ok <- Validation.await_timeout(await_timeout),
         {:ok, run_id} <- start_run.(Keyword.delete(options, :await_timeout)) do
      Run.await(run_id, await_timeout)
    end
  end

  defp executable_available?(path) when is_binary(path) do
    (Path.type(path) == :absolute and File.regular?(path)) or not is_nil(System.find_executable(path))
  end

  defp executable_available?(_path), do: false
end
