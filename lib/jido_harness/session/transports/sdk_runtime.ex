defmodule Jido.Harness.SessionAdapters.SDKRuntimeTransport do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Adapters.Helpers, Adapters.SDKMapper, Event, TurnRequest}

  def start_link({request, context}), do: GenServer.start_link(__MODULE__, {request, context})

  @impl true
  def init({request, context}) do
    Process.flag(:trap_exit, true)
    ref = make_ref()

    with {:ok, runtime, options, start_options} <- runtime_options(request, context, ref),
         {:ok, session, info} <- runtime.start_session([options: options, subscriber: {self(), ref}] ++ start_options) do
      {:ok,
       %{
         request: request,
         context: context,
         owner: context.owner,
         provider: context.provider,
         runtime: runtime,
         session: session,
         session_monitor: Process.monitor(session),
         subscription_ref: ref,
         projection_state: info.projection_state,
         provider_session_id: request.provider_session_id,
         active_turn_id: nil,
         closing?: false
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  rescue
    exception -> {:stop, exception}
  end

  @impl true
  def handle_call({:send, _request, _turn_id}, _from, %{active_turn_id: id} = state) when not is_nil(id),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:send, %TurnRequest{} = request, turn_id}, _from, state) do
    state = %{state | projection_state: reset_projection(state), active_turn_id: turn_id}

    case state.runtime.send_input(state.session, TurnRequest.text(request)) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | active_turn_id: nil}}
    end
  end

  def handle_call({:interrupt, requested}, _from, %{active_turn_id: turn_id} = state)
      when requested in [:active, turn_id] and not is_nil(turn_id) do
    case state.runtime.interrupt(state.session) do
      :ok -> {:reply, :ok, %{state | active_turn_id: nil}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:steer, %TurnRequest{} = request}, _from, %{provider: :amp, active_turn_id: id} = state)
      when not is_nil(id) do
    {:reply, state.runtime.send_input(state.session, TurnRequest.text(request)), state}
  end

  def handle_call({:steer, _request}, _from, state), do: {:reply, {:error, :unsupported}, state}

  def handle_call(:close, _from, state) do
    state = %{state | closing?: true}
    state.runtime.close(state.session)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({tag, ref, {:event, event}}, %{subscription_ref: ref} = state) when is_atom(tag) do
    {messages, projection_state} = state.runtime.project_event(event, state.projection_state)
    state = %{state | projection_state: projection_state}
    state = Enum.reduce(messages, state, &map_message/2)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{session_monitor: ref, session: pid} = state) do
    if state.closing?, do: {:stop, :normal, state}, else: {:stop, {:sdk_session_exit, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{session: pid} = state) do
    if state.closing?, do: {:noreply, state}, else: {:stop, {:sdk_session_exit, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.session && Process.alive?(state.session), do: state.runtime.close(state.session)
    :ok
  rescue
    _ -> :ok
  end

  defp map_message(message, state) do
    message
    |> sdk_events(state)
    |> Enum.reduce(state, fn event, state ->
      provider_session_id = event.provider_session_id || state.provider_session_id
      turn_id = state.active_turn_id

      event =
        case event.type do
          :run_started ->
            %{event | type: :provider_event, payload: Map.put(event.payload, "kind", "sdk_session_started")}

          :run_completed ->
            %{event | type: :turn_completed}

          :run_failed ->
            %{event | type: :turn_failed}

          :run_cancelled ->
            %{event | type: :turn_interrupted}

          type when type in [:turn_completed, :turn_failed, :turn_interrupted] ->
            event

          _ ->
            event
        end

      event = %{event | provider: state.provider, provider_session_id: provider_session_id, turn_id: turn_id}
      Jido.Harness.SessionAdapter.emit(state.owner, event)

      active_turn_id = if Event.turn_terminal?(event), do: nil, else: state.active_turn_id
      %{state | provider_session_id: provider_session_id, active_turn_id: active_turn_id}
    end)
  end

  defp sdk_events(message, %{provider: :amp}), do: SDKMapper.amp(message)
  defp sdk_events(message, %{provider: :gemini, provider_session_id: sid}), do: SDKMapper.gemini(message, sid)

  defp reset_projection(%{provider: :amp, runtime: runtime, session: session}),
    do: runtime.new_projection_state(runtime.info(session))

  defp reset_projection(%{provider: :gemini, runtime: runtime}), do: runtime.new_projection_state()

  defp runtime_options(request, %{provider: :amp} = context, ref) do
    provider = Helpers.provider_options(request.provider_options, Jido.Harness.Adapters.Amp.spec().provider_options)

    attrs =
      provider
      |> Map.put(:cwd, request.cwd)
      |> Map.put(:env, Map.merge(Map.get(context.config, :env, %{}), request.env))
      |> Map.put(:continue_thread, request.provider_session_id)
      |> Map.put(:mcp_config, request.mcp_config)
      |> Map.put(:model_payload, request.model)
      |> Map.put(:thinking, not is_nil(request.reasoning_effort))
      |> Map.put(:stream_timeout_ms, Helpers.sdk_timeout(:infinity))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    options = struct(AmpSdk.Types.Options, attrs) |> AmpSdk.Types.Options.validate!()
    {:ok, AmpSdk.Runtime.CLI, options, [input: [], session_event_tag: tag(:amp, ref)]}
  end

  defp runtime_options(request, %{provider: :gemini} = context, ref) do
    provider = Helpers.provider_options(request.provider_options, Jido.Harness.Adapters.Gemini.spec().provider_options)

    attrs =
      provider
      |> Map.merge(%{
        model: request.model,
        approval_mode: gemini_approval(request.approval_mode),
        sandbox: request.sandbox_mode == :workspace_write,
        include_directories: request.add_dirs || [],
        allowed_tools: request.allowed_tools || [],
        output_format: "stream-json",
        cwd: request.cwd,
        env: Map.merge(Map.get(context.config, :env, %{}), request.env),
        system_prompt: request.system_prompt,
        resume: request.provider_session_id,
        timeout_ms: Helpers.sdk_timeout(:infinity)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    options = struct(GeminiCliSdk.Options, attrs) |> GeminiCliSdk.Options.validate!()
    {:ok, GeminiCliSdk.Runtime.CLI, options, [prompt: "", session_event_tag: tag(:gemini, ref)]}
  end

  defp tag(provider, _ref), do: String.to_atom("jido_harness_#{provider}_session")
  defp gemini_approval(:default), do: nil
  defp gemini_approval(:prompt), do: :default
  defp gemini_approval(:auto_edit), do: :auto_edit
  defp gemini_approval(:auto_approve), do: :yolo
end
