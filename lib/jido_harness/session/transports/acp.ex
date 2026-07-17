defmodule Jido.Harness.SessionAdapters.ACPTransport do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{ApprovalResponse, Event, ProcessEvent, Protocol.JSONL, TurnRequest}

  def start_link({request, context}), do: GenServer.start_link(__MODULE__, {request, context})

  @impl true
  def init({request, context}) do
    with {:ok, executable, argv, env} <- command(request, context),
         {:ok, process_id} <-
           context.process_manager.start_owned_process(
             %{
               executable: executable,
               argv: argv,
               cwd: request.cwd,
               env: context.config |> configured_env() |> Map.merge(env) |> Map.merge(request.env),
               stdin: true,
               pty: false,
               runtime_timeout_ms: :infinity,
               idle_timeout_ms: :infinity,
               metadata: %{session_id: context.session_id, provider: context.provider, transport: :acp}
             },
             context.owner
           ),
         {:ok, stream} <- context.process_manager.stream_process(process_id) do
      {:ok,
       %{
         request: request,
         context: context,
         owner: context.owner,
         provider: context.provider,
         process_id: process_id,
         stream: stream,
         reader: nil,
         buffer: "",
         next_id: 1,
         pending: %{},
         approvals: %{},
         provider_session_id: request.provider_session_id,
         active_turn_id: nil,
         interrupted_turns: MapSet.new(),
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
        Enum.each(state.stream, &send(parent, {:acp_process_event, &1}))
      end)

    {:noreply, %{state | reader: reader}}
  end

  @impl true
  def handle_call({:initialize, request}, from, state) do
    params = %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      },
      "clientInfo" => %{"name" => "jido_harness", "title" => "Jido Harness", "version" => "2.0.0"}
    }

    with {:ok, state} <- request(state, "initialize", params, {:initialize, from, request}) do
      {:noreply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send, _request, _turn_id}, _from, %{active_turn_id: id} = state) when not is_nil(id),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:send, %TurnRequest{} = turn, turn_id}, _from, state) do
    params = %{"sessionId" => state.provider_session_id, "prompt" => prompt_blocks(turn, state.request.cwd)}

    case request(state, "session/prompt", params, {:turn, turn_id}) do
      {:ok, state} -> {:reply, :ok, %{state | active_turn_id: turn_id}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, requested}, _from, %{active_turn_id: turn_id} = state)
      when requested in [:active, turn_id] and not is_nil(turn_id) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "session/cancel",
      "params" => %{"sessionId" => state.provider_session_id}
    }

    case write(state, notification) do
      :ok ->
        {:reply, :ok, %{state | active_turn_id: nil, interrupted_turns: MapSet.put(state.interrupted_turns, turn_id)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:respond_approval, {request_id, %ApprovalResponse{} = response}}, _from, state) do
    case Map.pop(state.approvals, request_id) do
      {nil, _approvals} ->
        {:reply, {:error, :unknown_request}, state}

      {%{id: id, params: params}, approvals} ->
        result = permission_result(params, response)
        reply = write(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
        {:reply, reply, %{state | approvals: approvals}}
    end
  end

  def handle_call(:close, _from, state) do
    state = %{state | closing?: true}
    state = deny_pending_approvals(state)

    if state.provider_session_id && state.active_turn_id do
      _ =
        write(state, %{
          "jsonrpc" => "2.0",
          "method" => "session/cancel",
          "params" => %{"sessionId" => state.provider_session_id}
        })
    end

    _ = state.context.process_manager.cancel_process(state.process_id)
    if state.reader, do: Task.shutdown(state.reader, 5_000)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:acp_process_event, %ProcessEvent{type: :stdout, data: data}}, state) do
    {records, buffer} = JSONL.push(state.buffer, data)
    state = Enum.reduce(records, %{state | buffer: buffer}, &handle_record/2)
    {:noreply, state}
  end

  def handle_info({:acp_process_event, %ProcessEvent{type: :stderr, data: data}}, state) do
    emit(state, :provider_event, %{"stream" => "stderr", "data" => data, "kind" => "acp_log"})
    {:noreply, state}
  end

  def handle_info({:acp_process_event, %ProcessEvent{type: type, data: data}}, state)
      when type in [:failed, :timed_out] do
    if state.active_turn_id do
      emit(state, :turn_failed, %{"error" => inspect(data || type)}, turn_id: state.active_turn_id)
    end

    {:stop, {:process_failed, type}, state}
  end

  def handle_info({:acp_process_event, %ProcessEvent{type: type}}, state) when type in [:exited, :cancelled] do
    if state.closing?, do: {:noreply, state}, else: {:stop, {:process_exited, type}, state}
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

  defp handle_record({:ok, %{"id" => id} = message}, state) when not is_nil(id) and not is_map_key(message, "method") do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        emit(state, :provider_event, %{"kind" => "uncorrelated_response", "message" => message})
        state

      {{:initialize, from, request}, pending} ->
        state = %{state | pending: pending}

        case rpc_result(message) do
          {:ok, _result} -> begin_session(state, from, request)
          {:error, reason} -> reply_error(state, from, reason)
        end

      {{:open, from}, pending} ->
        state = %{state | pending: pending}

        case rpc_result(message) do
          {:ok, result} ->
            provider_session_id = result["sessionId"] || result["session_id"]

            if is_binary(provider_session_id) do
              GenServer.reply(from, {:ok, provider_session_id})
              %{state | provider_session_id: provider_session_id}
            else
              reply_error(state, from, {:invalid_session_response, result})
            end

          {:error, reason} ->
            reply_error(state, from, reason)
        end

      {{:turn, turn_id}, pending} ->
        state = %{state | pending: pending}
        finish_prompt(state, turn_id, message)
    end
  end

  defp handle_record({:ok, %{"method" => "session/update", "params" => params} = raw}, state) do
    update = params["update"] || %{}
    turn_id = state.active_turn_id

    update
    |> map_update(raw)
    |> Enum.each(fn event ->
      event = %{event | provider_session_id: state.provider_session_id, turn_id: event.turn_id || turn_id}
      Jido.Harness.SessionAdapter.emit(state.owner, event)
    end)

    state
  end

  defp handle_record({:ok, %{"method" => "session/request_permission", "id" => id, "params" => params}}, state) do
    request_id = to_string(id)

    emit(state, :approval_requested, permission_payload(params),
      request_id: request_id,
      turn_id: state.active_turn_id
    )

    %{state | approvals: Map.put(state.approvals, request_id, %{id: id, params: params})}
  end

  defp handle_record({:ok, %{"method" => method} = raw}, state) do
    emit(state, :provider_event, %{"kind" => "acp_notification", "method" => method, "message" => raw})
    state
  end

  defp handle_record({:ok, raw}, state) do
    emit(state, :provider_event, %{"kind" => "acp_message", "message" => raw})
    state
  end

  defp handle_record({:error, line, reason}, state) do
    emit(state, :provider_event, %{
      "kind" => "decode_error",
      "line" => line,
      "error" => Exception.message(reason)
    })

    state
  end

  defp begin_session(state, from, request) do
    params = %{"cwd" => request.cwd, "mcpServers" => mcp_servers(request.mcp_config)}

    {method, params} =
      if is_binary(request.provider_session_id) do
        {"session/load", Map.put(params, "sessionId", request.provider_session_id)}
      else
        {"session/new", params}
      end

    case request(state, method, params, {:open, from}) do
      {:ok, state} -> state
      {:error, reason} -> reply_error(state, from, reason)
    end
  end

  defp finish_prompt(state, turn_id, message) do
    interrupted? = MapSet.member?(state.interrupted_turns, turn_id)

    case rpc_result(message) do
      {:ok, result} ->
        type = if interrupted? or result["stopReason"] == "cancelled", do: :turn_interrupted, else: :turn_completed
        emit(state, type, %{"stop_reason" => result["stopReason"]}, turn_id: turn_id)

      {:error, reason} ->
        type = if interrupted?, do: :turn_interrupted, else: :turn_failed
        emit(state, type, %{"error" => inspect(reason)}, turn_id: turn_id)
    end

    %{
      state
      | active_turn_id: if(state.active_turn_id == turn_id, do: nil, else: state.active_turn_id),
        interrupted_turns: MapSet.delete(state.interrupted_turns, turn_id)
    }
  end

  defp request(state, method, params, pending_value) do
    id = state.next_id
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case write(state, message) do
      :ok -> {:ok, %{state | next_id: id + 1, pending: Map.put(state.pending, id, pending_value)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rpc_result(%{"error" => error}), do: {:error, error}
  defp rpc_result(%{"result" => result}), do: {:ok, result || %{}}
  defp rpc_result(message), do: {:error, {:invalid_rpc_response, message}}

  defp reply_error(state, from, reason) do
    GenServer.reply(from, {:error, reason})
    state
  end

  defp map_update(%{"sessionUpdate" => type} = update, raw) do
    case type do
      "agent_message_chunk" -> text_event(:output_text_delta, update, raw)
      "agent_thought_chunk" -> text_event(:thinking_delta, update, raw)
      "tool_call" -> [event(:tool_call, update, raw)]
      "tool_call_update" -> [event(:tool_result, update, raw)]
      "plan" -> [event(:plan_updated, update, raw)]
      "usage_update" -> [event(:usage, Map.drop(update, ["sessionUpdate"]), raw)]
      _ -> [event(:provider_event, %{"kind" => "acp_update", "update" => update}, raw)]
    end
  end

  defp map_update(update, raw), do: [event(:provider_event, %{"kind" => "acp_update", "update" => update}, raw)]

  defp text_event(type, update, raw) do
    content = update["content"] || %{}
    text = content["text"] || update["text"]
    if is_binary(text), do: [event(type, %{"text" => text}, raw)], else: [event(:provider_event, update, raw)]
  end

  defp event(type, payload, raw), do: Event.new!(type: type, provider: :acp, payload: payload, raw: raw)

  defp emit(state, type, payload, options \\ []) do
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

  defp prompt_blocks(%TurnRequest{} = request, cwd) do
    blocks =
      if request.content == [] do
        [%{"type" => "text", "text" => TurnRequest.text(request)}]
      else
        Enum.map(request.content, &stringify_keys/1)
      end

    blocks ++
      Enum.map(request.attachments, fn path ->
        path = Path.expand(path, cwd)
        %{"type" => "resource_link", "uri" => file_uri(path), "name" => Path.basename(path)}
      end)
  end

  defp permission_payload(params) do
    %{
      "tool_call" => params["toolCall"] || params["tool_call"],
      "options" => params["options"] || []
    }
  end

  defp permission_result(params, response) do
    options = params["options"] || []
    option = select_permission_option(options, response)

    if option do
      %{"outcome" => %{"outcome" => "selected", "optionId" => option["optionId"] || option["option_id"]}}
    else
      %{"outcome" => %{"outcome" => "cancelled"}}
    end
  end

  defp select_permission_option(options, %{decision: :approve, scope: :session}) do
    find_option(options, ["allow_always", "allow_session", "always", "allow_once"])
  end

  defp select_permission_option(options, %{decision: :approve}) do
    find_option(options, ["allow_once", "allow", "approve", "allow_always"])
  end

  defp select_permission_option(options, %{decision: :deny, scope: :session}) do
    find_option(options, ["reject_always", "deny_always", "reject_once", "deny"])
  end

  defp select_permission_option(options, %{decision: :deny}) do
    find_option(options, ["reject_once", "deny", "reject", "reject_always"])
  end

  defp find_option(options, kinds) do
    Enum.find_value(kinds, fn kind ->
      Enum.find(options, fn option ->
        option["kind"] == kind or String.downcase(to_string(option["name"] || "")) == kind
      end)
    end)
  end

  defp deny_pending_approvals(state) do
    response = %ApprovalResponse{decision: :deny, scope: :once, reason: "session closed", provider_options: %{}}

    Enum.each(state.approvals, fn {_request_id, %{id: id, params: params}} ->
      _ = write(state, %{"jsonrpc" => "2.0", "id" => id, "result" => permission_result(params, response)})
    end)

    %{state | approvals: %{}}
  end

  defp command(request, context) do
    cli_path = option(request.provider_options, :cli_path)

    case context.provider do
      :kimi -> {:ok, cli_path || configured_cli(context, "kimi"), ["acp"], %{"KIMI_CODE_NO_AUTO_UPDATE" => "1"}}
      :opencode -> {:ok, cli_path || configured_cli(context, "opencode"), ["acp"], %{}}
      provider -> {:error, {:unsupported_acp_provider, provider}}
    end
  end

  defp configured_cli(context, default) do
    config = context.config
    config[:cli_path] || config["cli_path"] || default
  end

  defp configured_env(config) do
    config[:env] || config["env"] || %{}
  end

  defp option(options, key), do: Map.get(options, key) || Map.get(options, Atom.to_string(key))
  defp mcp_servers(nil), do: []
  defp mcp_servers(value) when is_list(value), do: value
  defp mcp_servers(value) when is_map(value), do: Map.values(value)
  defp mcp_servers(_value), do: []

  defp write(state, value), do: state.context.process_manager.send_input(state.process_id, JSONL.encode(value))

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp file_uri(path) do
    path = Path.expand(path)
    "file://" <> URI.encode(path)
  end
end
