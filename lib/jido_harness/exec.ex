defmodule Jido.Harness.Exec do
  @moduledoc """
  Runtime orchestration helpers for provider execution in shell-backed sessions.

  These functions provide the direct library API over the underlying runtime modules.
  Matching `Jido.Harness.Actions.*` wrappers exist for Jido-native workflow composition.
  """

  alias Jido.Harness.Exec.{Preflight, ProviderRuntime, Stream, Workspace}

  @doc """
  Provisions the workspace runtime context for a session.
  """
  @spec provision_workspace(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def provision_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) and is_list(opts) do
    Workspace.provision_workspace(workspace_id, opts)
  end

  @doc """
  Validates shared runtime dependencies available to all providers.
  """
  @spec validate_shared_runtime(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_shared_runtime(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Preflight.validate_shared_runtime(session_id, opts)
  end

  @doc """
  Validates provider-specific runtime dependencies before execution.
  """
  @spec validate_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_provider_runtime(provider, session_id, opts \\ [])
      when is_atom(provider) and is_binary(session_id) and is_list(opts) do
    ProviderRuntime.validate_provider_runtime(provider, session_id, opts)
  end

  @doc """
  Bootstraps provider runtime state required for a run.
  """
  @spec bootstrap_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bootstrap_provider_runtime(provider, session_id, opts \\ [])
      when is_atom(provider) and is_binary(session_id) and is_list(opts) do
    ProviderRuntime.bootstrap_provider_runtime(provider, session_id, opts)
  end

  @doc """
  Runs a provider stream for a command or normalized options payload.
  """
  @spec run_stream(atom(), String.t(), String.t(), String.t() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_stream(provider, session_id, cwd, command_or_opts)
      when is_atom(provider) and is_binary(session_id) and is_binary(cwd) do
    Stream.run_stream(provider, session_id, cwd, command_or_opts)
  end

  @doc """
  Tears down workspace artifacts and returns a normalized teardown summary map.
  """
  @spec teardown_workspace(String.t(), keyword()) :: map()
  def teardown_workspace(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Workspace.teardown_workspace(session_id, opts)
  end
end
