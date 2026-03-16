defmodule Jido.Harness.Runtime do
  @moduledoc """
  Helpers for dispatching runtime drivers through the Session Control IR.
  """

  alias Jido.Harness.{
    Error,
    Event,
    ExecutionEvent,
    ExecutionResult,
    ExecutionStatus,
    RunHandle,
    RunRequest,
    RuntimeDescriptor,
    SessionHandle
  }

  @doc "Returns true when a module exposes the runtime driver callback surface."
  @spec runtime_driver?(module()) :: boolean()
  def runtime_driver?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and driver_callbacks_exported?(module)
  end

  @doc "Returns the runtime descriptor for a driver module."
  @spec runtime_descriptor(module(), keyword()) :: {:ok, RuntimeDescriptor.t()} | {:error, term()}
  def runtime_descriptor(module, opts \\ []) when is_atom(module) and is_list(opts) do
    case module.runtime_descriptor(opts) do
      %RuntimeDescriptor{} = descriptor ->
        {:ok, descriptor}

      other ->
        {:error,
         Error.execution_error("Runtime driver runtime_descriptor/1 must return %Jido.Harness.RuntimeDescriptor{}", %{
           module: inspect(module),
           value: inspect(other)
         })}
    end
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver runtime_descriptor/1 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  @doc "Starts a runtime-driver session."
  @spec start_session(module(), keyword()) :: {:ok, SessionHandle.t()} | {:error, term()}
  def start_session(module, opts \\ []) when is_atom(module) and is_list(opts) do
    case module.start_session(opts) do
      {:ok, %SessionHandle{} = session} ->
        {:ok, session}

      {:error, _} = error ->
        error

      other ->
        {:error,
         Error.execution_error("Runtime driver start_session/1 must return {:ok, session} | {:error, term()}", %{
           module: inspect(module),
           value: inspect(other)
         })}
    end
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver start_session/1 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  @doc "Stops a runtime-driver session."
  @spec stop_session(module(), SessionHandle.t()) :: :ok | {:error, term()}
  def stop_session(module, %SessionHandle{} = session) when is_atom(module) do
    normalize_unit_result(module, "stop_session/1", module.stop_session(session))
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver stop_session/1 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  @doc "Runs a streaming execution against an existing runtime session."
  @spec stream_run(module(), SessionHandle.t(), RunRequest.t(), keyword()) ::
          {:ok, RunHandle.t(), Enumerable.t(ExecutionEvent.t())} | {:error, term()}
  def stream_run(module, %SessionHandle{} = session, %RunRequest{} = request, opts \\ [])
      when is_atom(module) and is_list(opts) do
    case module.stream_run(session, request, opts) do
      {:ok, %RunHandle{} = run, stream} ->
        if Enumerable.impl_for(stream) != nil do
          {:ok, run, Stream.map(stream, &ensure_execution_event!/1)}
        else
          {:error,
           Error.execution_error("Runtime driver stream_run/3 must return an Enumerable stream", %{
             module: inspect(module),
             value: inspect(stream)
           })}
        end

      {:ok, other_run, _stream} ->
        {:error,
         Error.execution_error("Runtime driver stream_run/3 must return %Jido.Harness.RunHandle{}", %{
           module: inspect(module),
           value: inspect(other_run)
         })}

      {:error, _} = error ->
        error

      other ->
        {:error,
         Error.execution_error("Runtime driver stream_run/3 must return {:ok, run, stream} | {:error, term()}", %{
           module: inspect(module),
           value: inspect(other)
         })}
    end
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver stream_run/3 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  @doc "Runs a streaming runtime driver and maps runtime events back to legacy harness events."
  @spec stream_legacy_events(module(), RunRequest.t(), keyword()) ::
          {:ok, Enumerable.t(Event.t())} | {:error, term()}
  def stream_legacy_events(module, %RunRequest{} = request, opts \\ []) when is_atom(module) do
    with {:ok, %SessionHandle{} = session} <- start_runtime_session(module, request, opts) do
      case stream_run(module, session, request, opts) do
        {:ok, _run, stream} ->
          {:ok,
           Stream.transform(
             stream,
             fn -> session end,
             fn %ExecutionEvent{} = event, session_handle ->
               {[to_legacy_event!(event)], session_handle}
             end,
             fn session_handle ->
               _ = safe_stop_session(module, session_handle)
               []
             end
           )}

        {:error, _} = error ->
          _ = safe_stop_session(module, session)
          error
      end
    end
  end

  @doc "Runs a runtime driver to completion against an existing session."
  @spec run_result(module(), SessionHandle.t(), RunRequest.t(), keyword()) ::
          {:ok, ExecutionResult.t()} | {:error, term()}
  def run_result(module, %SessionHandle{} = session, %RunRequest{} = request, opts \\ [])
      when is_atom(module) and is_list(opts) do
    invoke_run(module, session, request, opts)
  end

  @doc "Runs a runtime driver to completion using a one-off session."
  @spec run_result_once(module(), RunRequest.t(), keyword()) :: {:ok, ExecutionResult.t()} | {:error, term()}
  def run_result_once(module, %RunRequest{} = request, opts \\ []) when is_atom(module) do
    case start_runtime_session(module, request, opts) do
      {:ok, %SessionHandle{} = session} ->
        run_with_session_cleanup(module, session, fn ->
          run_result(module, session, request, opts)
        end)

      {:error, _} = error ->
        error
    end
  end

  @doc "Cancels an existing runtime-driver run."
  @spec cancel_run(module(), SessionHandle.t(), RunHandle.t() | String.t()) :: :ok | {:error, term()}
  def cancel_run(module, %SessionHandle{} = session, run_or_id) when is_atom(module) do
    normalize_unit_result(module, "cancel_run/2", module.cancel_run(session, run_or_id))
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver cancel_run/2 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  @doc "Fetches runtime-driver session status."
  @spec session_status(module(), SessionHandle.t()) ::
          {:ok, ExecutionStatus.t()} | {:error, term()}
  def session_status(module, %SessionHandle{} = session) when is_atom(module) do
    case module.session_status(session) do
      {:ok, %ExecutionStatus{} = status} ->
        {:ok, status}

      {:error, _} = error ->
        error

      other ->
        {:error,
         Error.execution_error("Runtime driver session_status/1 must return {:ok, status} | {:error, term()}", %{
           module: inspect(module),
           value: inspect(other)
         })}
    end
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver session_status/1 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  @doc "Resolves an approval against an existing runtime session."
  @spec approve(module(), SessionHandle.t(), String.t(), :allow | :deny, keyword()) ::
          :ok | {:error, term()}
  def approve(module, %SessionHandle{} = session, approval_id, decision, opts \\ [])
      when is_atom(module) and is_binary(approval_id) and decision in [:allow, :deny] and is_list(opts) do
    if function_exported?(module, :approve, 4) do
      normalize_unit_result(module, "approve/4", module.approve(session, approval_id, decision, opts))
    else
      {:error,
       Error.execution_error("Runtime driver does not expose approve/4", %{
         module: inspect(module)
       })}
    end
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver approve/4 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  @doc "Fetches normalized cost data for an existing runtime session."
  @spec cost(module(), SessionHandle.t()) :: {:ok, map()} | {:error, term()}
  def cost(module, %SessionHandle{} = session) when is_atom(module) do
    if function_exported?(module, :cost, 1) do
      case module.cost(session) do
        {:ok, cost} when is_map(cost) ->
          {:ok, cost}

        {:error, _} = error ->
          error

        other ->
          {:error,
           Error.execution_error("Runtime driver cost/1 must return {:ok, map} | {:error, term()}", %{
             module: inspect(module),
             value: inspect(other)
           })}
      end
    else
      {:error,
       Error.execution_error("Runtime driver does not expose cost/1", %{
         module: inspect(module)
       })}
    end
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver cost/1 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  defp start_runtime_session(module, %RunRequest{} = request, opts) do
    session_opts = runtime_session_opts(request, opts)
    start_session(module, session_opts)
  end

  defp invoke_run(module, %SessionHandle{} = session, %RunRequest{} = request, opts) do
    if function_exported?(module, :run, 3) do
      case module.run(session, request, opts) do
        {:ok, %ExecutionResult{} = result} ->
          {:ok, result}

        {:error, _} = error ->
          error

        other ->
          {:error,
           Error.execution_error("Runtime driver run/3 must return {:ok, result} | {:error, term()}", %{
             module: inspect(module),
             value: inspect(other)
           })}
      end
    else
      {:error,
       Error.execution_error("Runtime driver does not expose run/3", %{
         module: inspect(module)
       })}
    end
  rescue
    error in [FunctionClauseError, UndefinedFunctionError, ArgumentError] ->
      {:error,
       Error.execution_error("Runtime driver run/3 invocation failed", %{
         module: inspect(module),
         error: Exception.message(error)
       })}
  end

  defp runtime_session_opts(%RunRequest{} = request, opts) do
    request_opts =
      []
      |> maybe_put(:cwd, request.cwd)
      |> maybe_put(:model, request.model)
      |> maybe_put(:max_turns, request.max_turns)
      |> maybe_put(:system_prompt, request.system_prompt)
      |> maybe_put(:allowed_tools, request.allowed_tools)
      |> maybe_put(:attachments, request.attachments)
      |> maybe_put(:metadata, request.metadata)
      |> maybe_put(:stream_timeout_ms, request.timeout_ms)

    Keyword.merge(request_opts, opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_execution_event!(%ExecutionEvent{} = event), do: event

  defp ensure_execution_event!(other) do
    raise ArgumentError,
          "Runtime driver stream must emit %Jido.Harness.ExecutionEvent{} values, got: #{inspect(other)}"
  end

  defp to_legacy_event!(%ExecutionEvent{} = event) do
    Event.new!(%{
      type: event.type,
      provider: event.provider || :unknown,
      session_id: event.session_id,
      timestamp: event.timestamp,
      payload: event.payload,
      raw: event.raw
    })
  end

  defp safe_stop_session(module, %SessionHandle{} = session) do
    stop_session(module, session)
  rescue
    _ -> :ok
  end

  defp run_with_session_cleanup(module, %SessionHandle{} = session, fun) when is_function(fun, 0) do
    fun.()
  after
    _ = safe_stop_session(module, session)
  end

  defp normalize_unit_result(_module, _callback, :ok), do: :ok
  defp normalize_unit_result(_module, _callback, {:error, _} = error), do: error

  defp normalize_unit_result(module, callback, other) do
    {:error,
     Error.execution_error("Runtime driver #{callback} must return :ok | {:error, term()}", %{
       module: inspect(module),
       value: inspect(other)
     })}
  end

  defp driver_callbacks_exported?(module) do
    Enum.all?(
      [
        runtime_id: 0,
        runtime_descriptor: 1,
        start_session: 1,
        stop_session: 1,
        stream_run: 3,
        cancel_run: 2,
        session_status: 1
      ],
      fn {function_name, arity} -> function_exported?(module, function_name, arity) end
    )
  end
end
