defmodule Jido.Harness.SessionAdapters.PiRPCTransport do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Adapters.Helpers, Adapters.Pi, Event, ProcessEvent, Protocol.JSONL, TurnRequest}

  def start_link({request, context}), do: GenServer.start_link(__MODULE__, {request, context})

  @impl true
  def init({request, context}) do
    options = Helpers.provider_options(request.provider_options, Pi.spec().provider_options)
    executable = options[:cli_path] || Helpers.cli_path(context.config, Pi.spec().executable)

    with {:ok, argv} <- Pi.build_session_argv(request, options),
         {:ok, process_id} <-
           context.process_manager.start_owned_process(
             %{
               executable: executable,
               argv: argv,
               cwd: request.cwd,
               env:
                 context.config
                 |> configured_env()
                 |> Map.merge(request.env)
                 |> Map.put("PI_SKIP_VERSION_CHECK", "1")
                 |> Map.put("PI_TELEMETRY", "0"),
               stdin: true,
               pty: false,
               runtime_timeout_ms: :infinity,
               idle_timeout_ms: :infinity,
               metadata: %{session_id: context.session_id, provider: :pi, transport: :rpc}
             },
             context.owner
           ),
         {:ok, stream} <- context.process_manager.stream_process(process_id) do
      {:ok,
       %{
         request: request,
         context: context,
         owner: context.owner,
         process_id: process_id,
         stream: stream,
         reader: nil,
         buffer: "",
         active_turn_id: nil,
         interrupted_turn_id: nil,
         provider_session_id: request.provider_session_id,
         closing?: false
       }, {:continue, :start_reader}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_reader, state) do
    parent = self()

    reader =
      Task.Supervisor.async_nolink(Jido.Harness.SessionTaskSupervisor, fn ->
        Enum.each(state.stream, &send(parent, {:pi_process_event, &1}))
      end)

    {:noreply, %{state | reader: reader}}
  end

  @impl true
  def handle_call({:send, _request, _turn_id}, _from, %{active_turn_id: id} = state) when not is_nil(id),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:send, %TurnRequest{} = request, turn_id}, _from, state) do
    command = %{"type" => "prompt", "message" => TurnRequest.text(request)}

    with :ok <- set_turn_reasoning(state, request.reasoning_effort),
         :ok <- write(state, command) do
      {:reply, :ok, %{state | active_turn_id: turn_id}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, requested}, _from, %{active_turn_id: turn_id} = state)
      when requested in [:active, turn_id] and not is_nil(turn_id) do
    case write(state, %{"type" => "abort"}) do
      :ok ->
        {:reply, :ok, %{state | active_turn_id: nil, interrupted_turn_id: turn_id}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:steer, %TurnRequest{} = request, _request_id}, _from, %{active_turn_id: turn_id} = state)
      when not is_nil(turn_id) do
    {:reply, write(state, %{"type" => "steer", "message" => TurnRequest.text(request)}), state}
  end

  def handle_call({:steer, _request, _request_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:configure, changes}, _from, state) when is_map(changes) do
    with :ok <- validate_model_change(changes, state.request.provider_options) do
      commands =
        []
        |> maybe_model(changes, state.request.provider_options)
        |> maybe_thinking(changes)

      result =
        Enum.reduce_while(commands, :ok, fn command, :ok ->
          case write(state, command) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:reply, result, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    state = %{state | closing?: true}
    _ = state.context.process_manager.cancel_process(state.process_id)
    if state.reader, do: Task.shutdown(state.reader, 5_000)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:pi_process_event, %ProcessEvent{type: :stdout, data: data}}, state) do
    {records, buffer} = JSONL.push(state.buffer, data)
    state = Enum.reduce(records, %{state | buffer: buffer}, &handle_record/2)
    {:noreply, state}
  end

  def handle_info({:pi_process_event, %ProcessEvent{type: :stderr, data: data}}, state) do
    emit(state, Event.new!(type: :provider_event, provider: :pi, payload: %{"stream" => "stderr", "data" => data}))
    {:noreply, state}
  end

  def handle_info({:pi_process_event, %ProcessEvent{type: type, data: data}}, state)
      when type in [:failed, :timed_out] do
    if state.active_turn_id do
      emit(
        state,
        Event.new!(
          type: :turn_failed,
          provider: :pi,
          provider_session_id: state.provider_session_id,
          turn_id: state.active_turn_id,
          payload: %{"error" => inspect(data || type)}
        )
      )
    end

    {:stop, {:process_failed, type}, state}
  end

  def handle_info({:pi_process_event, %ProcessEvent{type: type}}, state) when type in [:exited, :cancelled] do
    if state.closing? do
      {:noreply, state}
    else
      {:stop, {:process_exited, type}, state}
    end
  end

  def handle_info({ref, _result}, %{reader: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | reader: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reader: %{ref: ref}} = state) do
    if state.closing?, do: {:noreply, %{state | reader: nil}}, else: {:stop, {:reader_exit, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.process_id, do: state.context.process_manager.cancel_process(state.process_id)
    :ok
  rescue
    _ -> :ok
  end

  defp handle_record({:ok, %{"type" => "response"} = raw}, state) do
    emit(
      state,
      Event.new!(type: :provider_event, provider: :pi, payload: Map.put(raw, "kind", "rpc_response"), raw: raw)
    )

    state
  end

  defp handle_record({:ok, raw}, state) do
    {state, events} =
      raw
      |> Pi.map_event()
      |> Enum.reduce({state, []}, fn event, {state, events} ->
        provider_session_id = event.provider_session_id || state.provider_session_id
        turn_id = event.turn_id || state.interrupted_turn_id || state.active_turn_id

        event =
          case event.type do
            :run_started -> %{event | type: :provider_event, payload: Map.put(event.payload, "kind", "session_started")}
            :run_failed -> %{event | type: :turn_failed}
            :run_cancelled -> %{event | type: :turn_interrupted}
            _ -> event
          end

        state = %{state | provider_session_id: provider_session_id}

        state =
          if Event.turn_terminal?(event) and is_nil(state.interrupted_turn_id),
            do: %{state | active_turn_id: nil},
            else: state

        {state, [%{event | provider_session_id: provider_session_id, turn_id: turn_id} | events]}
      end)

    Enum.each(Enum.reverse(events), &emit(state, &1))

    if raw["type"] == "turn_end" and state.interrupted_turn_id do
      %{state | interrupted_turn_id: nil}
    else
      state
    end
  end

  defp handle_record({:error, line, reason}, state) do
    emit(
      state,
      Event.new!(
        type: :provider_event,
        provider: :pi,
        payload: %{"kind" => "decode_error", "line" => line, "error" => Exception.message(reason)}
      )
    )

    state
  end

  defp write(state, value), do: state.context.process_manager.send_input(state.process_id, JSONL.encode(value))
  defp emit(state, event), do: Jido.Harness.SessionAdapter.emit(state.owner, event)

  defp set_turn_reasoning(_state, nil), do: :ok

  defp set_turn_reasoning(state, effort) when effort in [:low, :medium, :high],
    do: write(state, %{"type" => "set_thinking_level", "level" => Atom.to_string(effort)})

  defp maybe_model(commands, %{model: model}, provider_options) when is_binary(model) do
    provider = Map.get(provider_options, :model_provider) || Map.get(provider_options, "model_provider")

    if is_binary(provider) do
      commands ++ [%{"type" => "set_model", "provider" => provider, "modelId" => model}]
    else
      commands
    end
  end

  defp maybe_model(commands, _changes, _provider_options), do: commands

  defp maybe_thinking(commands, %{reasoning_effort: effort}) when effort in [:low, :medium, :high],
    do: commands ++ [%{"type" => "set_thinking_level", "level" => Atom.to_string(effort)}]

  defp maybe_thinking(commands, _changes), do: commands

  defp validate_model_change(%{model: model}, provider_options) when is_binary(model) do
    provider = Map.get(provider_options, :model_provider) || Map.get(provider_options, "model_provider")
    if is_binary(provider), do: :ok, else: {:error, :model_provider_required}
  end

  defp validate_model_change(_changes, _provider_options), do: :ok

  defp configured_env(config), do: config[:env] || config["env"] || %{}
end
