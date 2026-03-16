defmodule Jido.Harness.Runtime do
  @moduledoc """
  Helpers for dispatching runtime drivers through the Session Control IR.
  """

  alias Jido.Harness.{
    Error,
    Event,
    ExecutionEvent,
    ExecutionResult,
    RunRequest,
    SessionHandle
  }

  @doc "Returns true when a module exposes the runtime driver callback surface."
  @spec runtime_driver?(module()) :: boolean()
  def runtime_driver?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and driver_callbacks_exported?(module)
  end

  @doc "Runs a streaming runtime driver and maps runtime events back to legacy harness events."
  @spec stream_legacy_events(module(), RunRequest.t(), keyword()) ::
          {:ok, Enumerable.t(Event.t())} | {:error, term()}
  def stream_legacy_events(module, %RunRequest{} = request, opts \\ []) when is_atom(module) do
    with {:ok, %SessionHandle{} = session} <- start_runtime_session(module, request, opts) do
      case invoke_stream_run(module, session, request, opts) do
        {:ok, _run, stream} ->
          {:ok,
           Stream.transform(
             stream,
             fn -> session end,
             fn
               %ExecutionEvent{} = event, session_handle ->
                 {[to_legacy_event!(event)], session_handle}

               other, _session_handle ->
                 raise ArgumentError,
                       "Runtime driver stream must emit %Jido.Harness.ExecutionEvent{} values, got: #{inspect(other)}"
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

  @doc "Runs a runtime driver to completion and returns the normalized execution result."
  @spec run_result(module(), RunRequest.t(), keyword()) :: {:ok, ExecutionResult.t()} | {:error, term()}
  def run_result(module, %RunRequest{} = request, opts \\ []) when is_atom(module) do
    case start_runtime_session(module, request, opts) do
      {:ok, %SessionHandle{} = session} ->
        run_with_session_cleanup(module, session, fn ->
          invoke_run(module, session, request, opts)
        end)

      {:error, _} = error ->
        error
    end
  end

  defp start_runtime_session(module, %RunRequest{} = request, opts) do
    session_opts = runtime_session_opts(request, opts)

    case module.start_session(session_opts) do
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

  defp invoke_stream_run(module, %SessionHandle{} = session, %RunRequest{} = request, opts) do
    case module.stream_run(session, request, opts) do
      {:ok, _run, stream} = ok ->
        if Enumerable.impl_for(stream) != nil do
          ok
        else
          {:error,
           Error.execution_error("Runtime driver stream_run/3 must return an Enumerable stream", %{
             module: inspect(module),
             value: inspect(stream)
           })}
        end

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
    module.stop_session(session)
  rescue
    _ -> :ok
  end

  defp run_with_session_cleanup(module, %SessionHandle{} = session, fun) when is_function(fun, 0) do
    fun.()
  after
    _ = safe_stop_session(module, session)
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
