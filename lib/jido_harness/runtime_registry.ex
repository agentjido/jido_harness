defmodule Jido.Harness.RuntimeRegistry do
  @moduledoc """
  Looks up Session Control runtime-driver modules from explicit application
  configuration.

  ## Configuration

      config :jido_harness, :runtime_drivers, %{
        asm: MyApp.RuntimeAsmBridge.HarnessDriver,
        jido_session: Jido.Session.HarnessDriver
      }

      config :jido_harness, :default_runtime_driver, :jido_session
  """

  alias Jido.Harness.Error.RuntimeDriverNotFoundError

  @required_callbacks [
    runtime_id: 0,
    runtime_descriptor: 1,
    start_session: 1,
    stop_session: 1,
    stream_run: 3,
    cancel_run: 2,
    session_status: 1
  ]

  @type diagnostic_entry :: %{
          module: term(),
          status: :accepted | :rejected,
          reason:
            atom()
            | {:missing_callbacks, [{atom(), non_neg_integer()}]}
            | {:runtime_id_mismatch, atom()}
            | {:runtime_id_invalid, term()}
            | {:runtime_id_unavailable, term()}
        }

  @doc """
  Returns all configured runtime-driver bindings that pass conformance checks.
  """
  @spec runtime_drivers() :: %{optional(atom()) => module()}
  def runtime_drivers do
    diagnostics().runtime_drivers
  end

  @doc """
  Returns runtime-driver configuration diagnostics.
  """
  @spec diagnostics() :: %{
          configured: %{optional(term()) => diagnostic_entry()},
          runtime_drivers: %{optional(atom()) => module()}
        }
  def diagnostics do
    configured_diagnostics = configured_runtime_driver_diagnostics()

    runtime_drivers =
      configured_diagnostics
      |> Enum.reduce(%{}, fn
        {runtime_id, %{status: :accepted, module: module}}, acc when is_atom(runtime_id) ->
          Map.put(acc, runtime_id, module)

        _, acc ->
          acc
      end)

    %{
      configured: configured_diagnostics,
      runtime_drivers: runtime_drivers
    }
  end

  @doc """
  Looks up the runtime-driver module for a runtime id.
  """
  @spec lookup(atom()) :: {:ok, module()} | {:error, term()}
  def lookup(runtime_id) when is_atom(runtime_id) do
    case Map.fetch(runtime_drivers(), runtime_id) do
      {:ok, driver} ->
        {:ok, driver}

      :error ->
        {:error,
         RuntimeDriverNotFoundError.exception(
           message:
             "Runtime driver #{inspect(runtime_id)} is not available (explicit config required in :jido_harness, :runtime_drivers)",
           runtime_id: runtime_id
         )}
    end
  end

  @doc """
  Returns true if the runtime driver is available.
  """
  @spec available?(atom()) :: boolean()
  def available?(runtime_id) when is_atom(runtime_id), do: match?({:ok, _}, lookup(runtime_id))

  @doc """
  Returns the default runtime-driver id.

  Resolution order:
  - `:jido_harness, :default_runtime_driver` (if available)
  - first configured runtime-driver key in sorted order
  """
  @spec default_runtime_driver() :: atom() | nil
  def default_runtime_driver do
    configured = Application.get_env(:jido_harness, :default_runtime_driver)
    runtime_driver_map = runtime_drivers()

    if is_atom(configured) and Map.has_key?(runtime_driver_map, configured) do
      configured
    else
      runtime_driver_map |> Map.keys() |> Enum.sort() |> List.first()
    end
  end

  defp configured_runtime_driver_diagnostics do
    :jido_harness
    |> Application.get_env(:runtime_drivers, %{})
    |> Enum.reduce(%{}, fn
      {runtime_id, module}, acc when is_atom(runtime_id) ->
        Map.put(acc, runtime_id, candidate_diagnostic(runtime_id, module))

      {runtime_id, module}, acc ->
        Map.put(acc, runtime_id, %{
          module: module,
          status: :rejected,
          reason: :invalid_runtime_id_key
        })
    end)
  end

  defp candidate_diagnostic(runtime_id, candidate) do
    case ensure_runtime_driver_candidate(runtime_id, candidate) do
      {:ok, module} ->
        %{
          module: module,
          status: :accepted,
          reason: :ok
        }

      {:error, reason} ->
        %{
          module: candidate,
          status: :rejected,
          reason: reason
        }
    end
  end

  defp ensure_runtime_driver_candidate(_runtime_id, module) when not is_atom(module),
    do: {:error, :invalid_module}

  defp ensure_runtime_driver_candidate(runtime_id, module) do
    if Code.ensure_loaded?(module) do
      missing = missing_required_callbacks(module)

      if missing == [] do
        ensure_runtime_id_match(runtime_id, module)
      else
        {:error, {:missing_callbacks, missing}}
      end
    else
      {:error, :module_not_loaded}
    end
  end

  defp ensure_runtime_id_match(runtime_id, module) do
    case module.runtime_id() do
      ^runtime_id ->
        {:ok, module}

      value when is_atom(value) ->
        {:error, {:runtime_id_mismatch, value}}

      value ->
        {:error, {:runtime_id_invalid, value}}
    end
  rescue
    reason ->
      {:error, {:runtime_id_unavailable, reason}}
  end

  defp missing_required_callbacks(module) do
    @required_callbacks
    |> Enum.reject(fn {function, arity} -> function_exported?(module, function, arity) end)
  end
end
