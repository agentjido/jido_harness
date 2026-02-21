defmodule Jido.Harness.Exec do
  @moduledoc """
  Runtime orchestration helpers for provider execution in shell-backed sessions.

  Each helper delegates to a corresponding `Jido.Harness.Actions.*` module through
  `Jido.Exec.run/4` to keep runtime lifecycle execution Jido-native while preserving
  ergonomic function call sites.
  """

  alias Jido.Harness.Actions.{
    BootstrapProviderRuntime,
    ProvisionWorkspace,
    RunProviderStream,
    TeardownWorkspace,
    ValidateProviderRuntime,
    ValidateSharedRuntime
  }

  @spec provision_workspace(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def provision_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) and is_list(opts) do
    run_action(ProvisionWorkspace, %{workspace_id: workspace_id, opts: Map.new(opts)})
  end

  @spec validate_shared_runtime(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_shared_runtime(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    run_action(ValidateSharedRuntime, %{session_id: session_id, opts: Map.new(opts)})
  end

  @spec validate_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_provider_runtime(provider, session_id, opts \\ [])
      when is_atom(provider) and is_binary(session_id) and is_list(opts) do
    run_action(ValidateProviderRuntime, %{provider: provider, session_id: session_id, opts: Map.new(opts)})
  end

  @spec bootstrap_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bootstrap_provider_runtime(provider, session_id, opts \\ [])
      when is_atom(provider) and is_binary(session_id) and is_list(opts) do
    run_action(BootstrapProviderRuntime, %{provider: provider, session_id: session_id, opts: Map.new(opts)})
  end

  @spec run_stream(atom(), String.t(), String.t(), String.t() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_stream(provider, session_id, cwd, command_or_opts)
      when is_atom(provider) and is_binary(session_id) and is_binary(cwd) do
    run_action(RunProviderStream, %{
      provider: provider,
      session_id: session_id,
      cwd: cwd,
      command_or_opts: command_or_opts
    })
  end

  @spec teardown_workspace(String.t(), keyword()) :: map()
  def teardown_workspace(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    case run_action(TeardownWorkspace, %{session_id: session_id, opts: Map.new(opts)}) do
      {:ok, teardown} ->
        teardown

      {:error, reason} ->
        %{
          teardown_verified: false,
          teardown_attempts: 0,
          warnings: ["teardown action failed: #{inspect(reason)}"]
        }
    end
  end

  defp run_action(action, params) when is_atom(action) and is_map(params) do
    case Jido.Exec.run(action, params, %{}) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      {:error, reason, _directive} -> {:error, reason}
    end
  end
end
