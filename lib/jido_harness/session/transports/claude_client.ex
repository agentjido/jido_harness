defmodule Jido.Harness.SessionAdapters.ClaudeClientTransport do
  @moduledoc false
  use GenServer, restart: :temporary

  alias ClaudeAgentSDK.{Client, Message, Options}
  alias ClaudeAgentSDK.Permission.Result, as: PermissionResult
  alias Jido.Harness.{Adapters.Helpers, Adapters.SDKMapper, ApprovalResponse, Event, ID, TurnRequest}

  def start_link({request, context}), do: GenServer.start_link(__MODULE__, {request, context})

  @impl true
  def init({request, context}) do
    Process.flag(:trap_exit, true)
    owner = self()

    with {:ok, options} <- options(request, context, permission_callback(owner, request.approval_timeout_ms)),
         {:ok, client} <- Client.start_link(options),
         :ok <- Client.await_initialized(client, 30_000),
         {^client, subscription_ref} <- Client.subscribe(client) do
      {:ok,
       %{
         request: request,
         context: context,
         owner: context.owner,
         provider: context.provider,
         client: client,
         client_monitor: Process.monitor(client),
         subscription_ref: subscription_ref,
         provider_session_id: request.provider_session_id,
         active_turn_id: nil,
         approvals: %{},
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

  def handle_call({:send, %TurnRequest{} = turn, turn_id}, _from, state) do
    provider_session_id = state.provider_session_id || "default"

    case Client.query(state.client, TurnRequest.text(turn), provider_session_id) do
      :ok -> {:reply, :ok, %{state | active_turn_id: turn_id}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, requested}, _from, %{active_turn_id: turn_id} = state)
      when requested in [:active, turn_id] and not is_nil(turn_id) do
    case Client.interrupt(state.client) do
      :ok -> {:reply, :ok, %{state | active_turn_id: nil}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:respond_approval, {request_id, %ApprovalResponse{} = response}}, _from, state) do
    case Map.pop(state.approvals, request_id) do
      {nil, _approvals} ->
        {:reply, {:error, :unknown_request}, state}

      {%{pid: pid, ref: ref}, approvals} ->
        send(pid, {:jido_harness_approval, ref, approval_result(response)})
        {:reply, :ok, %{state | approvals: approvals}}
    end
  end

  def handle_call({:configure, changes}, _from, state) do
    result =
      Enum.reduce_while(changes, :ok, fn
        {:model, model}, :ok when is_binary(model) -> continue(Client.set_model(state.client, model))
        {:approval_mode, mode}, :ok -> continue(Client.set_permission_mode(state.client, permission_mode(mode)))
        {field, _value}, :ok -> {:halt, {:error, {:unsupported_configuration, field}}}
      end)

    {:reply, result, state}
  end

  def handle_call(:close, _from, state) do
    state = %{state | closing?: true}
    deny_pending(state.approvals)
    Client.stop(state.client)
    {:stop, :normal, :ok, %{state | approvals: %{}}}
  end

  @impl true
  def handle_info({:claude_message, %Message{} = message}, state), do: {:noreply, map_message(message, state)}

  def handle_info({:stream_event, ref, event}, %{subscription_ref: ref} = state) do
    message = %Message{
      type: :stream_event,
      data: %{
        event: Map.get(event, :raw_event, event),
        uuid: Map.get(event, :uuid),
        session_id: Map.get(event, :session_id),
        parent_tool_use_id: Map.get(event, :parent_tool_use_id)
      },
      raw: %{}
    }

    {:noreply, map_message(message, state)}
  end

  def handle_info({:jido_harness_permission, request_id, callback_pid, callback_ref, context}, state) do
    payload = %{
      "tool_name" => Map.get(context, :tool_name),
      "tool_input" => Map.get(context, :tool_input),
      "suggestions" => Map.get(context, :suggestions),
      "decision_reason" => Map.get(context, :decision_reason)
    }

    emit(state, :approval_requested, payload, request_id: request_id, turn_id: state.active_turn_id)
    approval = %{pid: callback_pid, ref: callback_ref}
    {:noreply, %{state | approvals: Map.put(state.approvals, request_id, approval)}}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{client_monitor: ref, client: pid} = state) do
    if state.closing?, do: {:stop, :normal, state}, else: {:stop, {:claude_client_exit, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{client: pid} = state) do
    if state.closing?, do: {:noreply, state}, else: {:stop, {:claude_client_exit, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    deny_pending(state.approvals)
    if state.client && Process.alive?(state.client), do: Client.stop(state.client)
    :ok
  rescue
    _ -> :ok
  end

  defp map_message(message, state) do
    message
    |> SDKMapper.claude()
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

          :turn_completed ->
            %{event | type: :provider_event, payload: Map.put(event.payload, "kind", "message_stop")}

          _ ->
            event
        end

      event = %{event | provider: state.provider, provider_session_id: provider_session_id, turn_id: turn_id}
      Jido.Harness.SessionAdapter.emit(state.owner, event)
      active_turn_id = if Event.turn_terminal?(event), do: nil, else: state.active_turn_id
      %{state | provider_session_id: provider_session_id, active_turn_id: active_turn_id}
    end)
  end

  defp options(request, context, callback) do
    provider = Helpers.provider_options(request.provider_options, provider_options(context.provider))

    with {:ok, env} <- provider_env(request, context, provider) do
      attrs =
        provider
        |> Map.drop([:cli_path, :base_url, :api_timeout_ms])
        |> Map.merge(%{
          model: request.model,
          system_prompt: request.system_prompt,
          allowed_tools: request.allowed_tools,
          disallowed_tools: request.disallowed_tools,
          add_dirs: request.add_dirs || [],
          permission_mode: permission_mode(request.approval_mode),
          sandbox: sandbox(request.sandbox_mode),
          cwd: request.cwd,
          env: env,
          resume: request.provider_session_id,
          max_thinking_tokens: thinking_tokens(request.reasoning_effort),
          output_format: :stream_json,
          include_partial_messages: true,
          preferred_transport: :control,
          timeout_ms: Helpers.sdk_timeout(:infinity),
          path_to_claude_code_executable: provider[:cli_path] || Map.get(context.config, :cli_path),
          can_use_tool: if(request.approval_mode == :auto_approve, do: nil, else: callback)
        })
        |> Map.merge(mcp(request.mcp_config))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      options = Options.new(attrs)
      _ = Options.to_args(options)
      {:ok, options}
    end
  end

  defp provider_env(request, %{provider: :zai} = context, provider) do
    Jido.Harness.Adapters.Zai.resolve_env(request, context.config, provider)
  end

  defp provider_env(request, context, _provider),
    do: {:ok, Map.merge(Map.get(context.config, :env, %{}), request.env)}

  defp permission_callback(owner, timeout) do
    fn context ->
      request_id = ID.generate("approval")
      ref = make_ref()
      send(owner, {:jido_harness_permission, request_id, self(), ref, Map.from_struct(context)})
      wait_for_approval(ref, timeout)
    end
  end

  defp wait_for_approval(ref, :infinity) do
    receive do
      {:jido_harness_approval, ^ref, result} -> result
    end
  end

  defp wait_for_approval(ref, timeout) do
    receive do
      {:jido_harness_approval, ^ref, result} -> result
    after
      timeout -> PermissionResult.deny("Jido Harness approval timed out")
    end
  end

  defp approval_result(%{decision: :approve}), do: PermissionResult.allow()
  defp approval_result(%{decision: :deny, reason: reason}), do: PermissionResult.deny(reason || "Denied by user")

  defp deny_pending(approvals) do
    Enum.each(approvals, fn {_id, %{pid: pid, ref: ref}} ->
      send(pid, {:jido_harness_approval, ref, PermissionResult.deny("Session closed")})
    end)
  end

  defp emit(state, type, payload, options) do
    Jido.Harness.SessionAdapter.emit(
      state.owner,
      Event.new!(
        type: type,
        provider: state.provider,
        provider_session_id: state.provider_session_id,
        turn_id: Keyword.get(options, :turn_id),
        request_id: Keyword.get(options, :request_id),
        payload: payload
      )
    )
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}
  defp provider_options(:claude), do: Jido.Harness.Adapters.Claude.spec().provider_options
  defp provider_options(:zai), do: Jido.Harness.Adapters.Zai.spec().provider_options
  defp permission_mode(:default), do: :default
  defp permission_mode(:prompt), do: :default
  defp permission_mode(:auto_edit), do: :accept_edits
  defp permission_mode(:auto_approve), do: :bypass_permissions
  defp sandbox(:default), do: nil
  defp sandbox(:read_only), do: %{enabled: true, filesystem: %{allow_write: []}}
  defp sandbox(:workspace_write), do: %{enabled: true}
  defp sandbox(:unrestricted), do: nil
  defp thinking_tokens(nil), do: nil
  defp thinking_tokens(:low), do: 1_024
  defp thinking_tokens(:medium), do: 4_096
  defp thinking_tokens(:high), do: 16_384
  defp mcp(nil), do: %{}
  defp mcp(value) when is_map(value), do: %{mcp_servers: value}
  defp mcp(value) when is_binary(value), do: %{mcp_config: value}
end
