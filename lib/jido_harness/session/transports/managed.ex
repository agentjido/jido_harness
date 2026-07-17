defmodule Jido.Harness.SessionAdapters.ManagedTransport do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Error, Event, RunRequest, SessionRequest, TurnRequest}

  def start_link({request, context}), do: GenServer.start_link(__MODULE__, {request, context})

  @impl true
  def init({%SessionRequest{} = request, context}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       request: request,
       context: context,
       provider: context.provider,
       owner: context.owner,
       active: nil,
       task: nil,
       closed?: false
     }}
  end

  @impl true
  def handle_call({:send, _request, _turn_id}, _from, %{closed?: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:send, _request, _turn_id}, _from, %{active: active} = state) when not is_nil(active),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:send, %TurnRequest{} = turn, turn_id}, _from, state) do
    with {:ok, attrs} <- run_attrs(state.request, turn),
         {:ok, run_id} <- Jido.Harness.Run.start(state.provider, attrs) do
      task =
        Task.Supervisor.async_nolink(Jido.Harness.SessionTaskSupervisor, fn ->
          consume_run(state.owner, state.provider, run_id, turn_id)
        end)

      {:reply, :ok, %{state | active: %{run_id: run_id, turn_id: turn_id}, task: task}}
    end
  end

  def handle_call({:interrupt, requested}, _from, %{active: %{run_id: run_id, turn_id: turn_id}} = state)
      when requested in [:active, turn_id] do
    reply = Jido.Harness.Run.cancel(run_id)

    request =
      case Jido.Harness.Run.await(run_id, 15_000) do
        {:ok, %{provider_session_id: id}} when is_binary(id) -> %{state.request | provider_session_id: id}
        _ -> state.request
      end

    if state.task, do: Task.shutdown(state.task, 1_000)
    {:reply, reply, %{state | request: request, active: nil, task: nil}}
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:configure, changes}, _from, state) when is_map(changes) do
    allowed = [:model, :reasoning_effort, :approval_mode, :sandbox_mode]

    case Enum.find(Map.keys(changes), &(&1 not in allowed)) do
      nil ->
        {:reply, :ok, %{state | request: struct!(state.request, changes)}}

      field ->
        {:reply, {:error, Error.validation("unsupported session configuration", details: %{field: field})}, state}
    end
  rescue
    exception ->
      {:reply, {:error, Error.validation("invalid session configuration", cause: exception)}, state}
  end

  def handle_call(:close, _from, state) do
    state = stop_active(state)
    {:stop, :normal, :ok, %{state | closed?: true}}
  end

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    request =
      case result do
        {:ok, %{provider_session_id: id}} when is_binary(id) -> %{state.request | provider_session_id: id}
        _ -> state.request
      end

    {:noreply, %{state | request: request, active: nil, task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}, active: active} = state) do
    event =
      Event.new!(%{
        type: :turn_failed,
        provider: state.provider,
        turn_id: active.turn_id,
        provider_session_id: state.request.provider_session_id,
        payload: %{"error" => "managed turn worker exited: #{inspect(reason)}"}
      })

    Jido.Harness.SessionAdapter.emit(state.owner, event)
    {:noreply, %{state | active: nil, task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = stop_active(state)
    :ok
  end

  defp consume_run(owner, provider, run_id, turn_id) do
    with {:ok, stream} <- Jido.Harness.Run.stream(run_id) do
      Enum.each(stream, fn event ->
        unless event.type == :run_started or Event.run_terminal?(event) or Event.turn_terminal?(event) do
          event = %{event | run_id: nil, session_id: nil, turn_id: turn_id}
          Jido.Harness.SessionAdapter.emit(owner, event)
        end
      end)
    end

    case Jido.Harness.Run.await(run_id, :infinity) do
      {:ok, result} ->
        type =
          case result.status do
            :completed -> :turn_completed
            :cancelled -> :turn_interrupted
            :failed -> :turn_failed
          end

        payload =
          %{"status" => Atom.to_string(result.status)}
          |> maybe_put("error", error_message(result.error))

        event =
          Event.new!(%{
            type: type,
            provider: provider,
            provider_session_id: result.provider_session_id,
            turn_id: turn_id,
            payload: payload
          })

        Jido.Harness.SessionAdapter.emit(owner, event)
        {:ok, result}

      {:error, reason} ->
        Jido.Harness.SessionAdapter.emit(
          owner,
          Event.new!(
            type: :turn_failed,
            provider: provider,
            turn_id: turn_id,
            payload: %{"error" => inspect(reason)}
          )
        )

        {:error, reason}
    end
  end

  defp run_attrs(%SessionRequest{} = session, %TurnRequest{} = turn) do
    prompt = TurnRequest.text(turn)

    attrs = %{
      prompt: prompt,
      cwd: session.cwd,
      model: session.model,
      provider_session_id: session.provider_session_id,
      runtime_timeout_ms: session.turn_runtime_timeout_ms,
      idle_timeout_ms: session.turn_idle_timeout_ms,
      system_prompt: session.system_prompt,
      allowed_tools: session.allowed_tools,
      disallowed_tools: session.disallowed_tools,
      add_dirs: session.add_dirs,
      mcp_config: session.mcp_config,
      approval_mode: session.approval_mode,
      sandbox_mode: session.sandbox_mode,
      attachments: Enum.map(turn.attachments, &Path.expand(&1, session.cwd)),
      reasoning_effort: turn.reasoning_effort || session.reasoning_effort,
      env: session.env,
      metadata: Map.merge(session.metadata, turn.metadata),
      provider_options: Map.merge(session.provider_options, turn.provider_options)
    }

    if prompt == "" do
      {:error, Error.validation("selected session transport does not support non-text content")}
    else
      case RunRequest.new(attrs) do
        {:ok, _request} -> {:ok, attrs}
        {:error, _reason} = error -> error
      end
    end
  end

  defp stop_active(%{active: nil} = state), do: state

  defp stop_active(state) do
    _ = Jido.Harness.Run.cancel(state.active.run_id)
    if state.task, do: Task.shutdown(state.task, 5_000)
    %{state | active: nil, task: nil}
  end

  defp error_message(nil), do: nil
  defp error_message(%{message: message}), do: message
  defp error_message(reason), do: inspect(reason)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
