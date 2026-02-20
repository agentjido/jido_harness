defmodule Jido.Harness.Exec do
  @moduledoc """
  Runtime orchestration helpers for provider execution in shell-backed sessions.
  """

  alias Jido.Harness.Exec.{Preflight, ProviderRuntime, Stream, Workspace}

  @spec provision_workspace(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate provision_workspace(workspace_id, opts \\ []), to: Workspace

  @spec validate_shared_runtime(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate validate_shared_runtime(session_id, opts \\ []), to: Preflight

  @spec validate_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate validate_provider_runtime(provider, session_id, opts \\ []), to: ProviderRuntime

  @spec bootstrap_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate bootstrap_provider_runtime(provider, session_id, opts \\ []), to: ProviderRuntime

  @spec run_stream(atom(), String.t(), String.t(), String.t() | keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate run_stream(provider, session_id, cwd, command_or_opts), to: Stream

  @spec teardown_workspace(String.t(), keyword()) :: map()
  defdelegate teardown_workspace(session_id, opts \\ []), to: Workspace
end
