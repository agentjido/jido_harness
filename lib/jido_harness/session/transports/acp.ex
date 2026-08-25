defmodule Jido.Harness.SessionAdapters.ACPTransport do
  @moduledoc false
  use GenServer, restart: :temporary

  alias ExMCP.ACP.Client
  alias Jido.Harness.{ApprovalResponse, Event, ID, TurnRequest}
  alias Jido.Harness.SessionAdapters.ACP.{ExMCPHandler, ExMCPTransport}

  @startup_timeout 30_000
  @protocol_timeout_margin 5_000
  @maximum_protocol_timeout 4_294_967_295

  def start_link({request, context}), do: GenServer.start_link(__MODULE__, {request, context})

  @impl true
  def init({request, context}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       request: request,
       context: context,
       owner: context.owner,
       provider: context.provider,
       client: nil,
       provider_session_id: request.provider_session_id,
       active_turn_id: nil,
       prompt_task: nil,
       approvals: %{},
       closing?: false
     }}
  end

  @impl true
  def handle_call({:initialize, request}, _from, state) do
    with {:ok, process_spec} <- process_spec(request, state.context) do
      case start_client(state, process_spec) do
        {:ok, client} -> initialize_session(client, request, state)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send, _request, _turn_id}, _from, %{active_turn_id: id} = state) when not is_nil(id),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:send, %TurnRequest{} = turn, turn_id}, _from, state) do
    client = state.client
    provider_session_id = state.provider_session_id
    prompt = prompt_blocks(turn, state.request.cwd)

    task =
      Task.Supervisor.async_nolink(Jido.Harness.SessionTaskSupervisor, fn ->
        Client.prompt(client, provider_session_id, prompt, timeout: :infinity)
      end)

    {:reply, :ok, %{state | active_turn_id: turn_id, prompt_task: task}}
  end

  def handle_call({:interrupt, requested}, _from, %{active_turn_id: turn_id} = state)
      when requested in [:active, turn_id] and not is_nil(turn_id) do
    state = deny_pending_approvals(state)
    :ok = Client.cancel(state.client, state.provider_session_id)
    stop_prompt_task(state.prompt_task)
    {:reply, :ok, %{state | active_turn_id: nil, prompt_task: nil}}
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:respond_approval, {request_id, %ApprovalResponse{} = response}}, _from, state) do
    case Map.pop(state.approvals, request_id) do
      {nil, _approvals} ->
        {:reply, {:error, :unknown_request}, state}

      {%{handler: handler, ref: ref, options: options}, approvals} ->
        send(handler, {:jido_harness_approval_response, ref, permission_outcome(options, response)})
        {:reply, :ok, %{state | approvals: approvals}}
    end
  end

  def handle_call(:close, _from, state) do
    state = %{state | closing?: true} |> deny_pending_approvals()
    stop_prompt_task(state.prompt_task)
    stop_client(state.client, state.provider_session_id)
    {:stop, :normal, :ok, %{state | client: nil, prompt_task: nil, active_turn_id: nil}}
  end

  @impl true
  def handle_info({:acp_session_update, provider_session_id, update}, state) do
    update
    |> map_update()
    |> Enum.each(fn event ->
      event = %{
        event
        | provider: state.provider,
          provider_session_id: provider_session_id,
          turn_id: event.turn_id || state.active_turn_id
      }

      Jido.Harness.SessionAdapter.emit(state.owner, event)
    end)

    {:noreply, state}
  end

  def handle_info(
        {:acp_permission_request, handler, ref, _provider_session_id, tool_call, options},
        state
      ) do
    request_id = ID.generate("request")

    emit(state, :approval_requested, permission_payload(tool_call, options),
      request_id: request_id,
      turn_id: state.active_turn_id
    )

    approval = %{handler: handler, ref: ref, options: options}

    {:noreply,
     %{
       state
       | approvals: Map.put(state.approvals, request_id, approval)
     }}
  end

  def handle_info({:acp_process_stderr, data}, state) do
    emit(state, :provider_event, %{"stream" => "stderr", "data" => data, "kind" => "acp_log"})
    {:noreply, state}
  end

  def handle_info({:acp_process_stopped, type, data}, %{closing?: false} = state) do
    if state.active_turn_id do
      emit(state, :turn_failed, %{"error" => inspect(data || type)}, turn_id: state.active_turn_id)
    end

    {:stop, {:process_stopped, type}, state}
  end

  def handle_info({:acp_process_stopped, _type, _data}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{prompt_task: %{ref: ref}, active_turn_id: turn_id} = state) do
    Process.demonitor(ref, [:flush])
    state = finish_prompt(state, turn_id, result)
    {:noreply, %{state | prompt_task: nil, active_turn_id: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{prompt_task: %{ref: ref}, active_turn_id: turn_id} = state) do
    emit(state, :turn_failed, %{"error" => "ACP prompt worker exited: #{inspect(reason)}"}, turn_id: turn_id)
    {:noreply, %{state | prompt_task: nil, active_turn_id: nil}}
  end

  def handle_info({:EXIT, client, reason}, %{client: client, closing?: false} = state) when is_pid(client),
    do: {:stop, {:ex_mcp_client_exit, reason}, %{state | client: nil}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = deny_pending_approvals(state)
    stop_prompt_task(state.prompt_task)
    stop_client(state.client, state.provider_session_id)
    :ok
  rescue
    _exception -> :ok
  end

  defp start_client(state, process_spec) do
    Client.start_link(
      transport_mod: ExMCPTransport,
      harness_transport: [
        process_manager: state.context.process_manager,
        process_owner: state.context.owner,
        process_spec: process_spec,
        listener: self()
      ],
      handler: ExMCPHandler,
      handler_opts: [transport: self()],
      client_info: %{
        "name" => "jido_harness",
        "title" => "Jido Harness",
        "version" => Jido.Harness.version()
      },
      capabilities: %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      },
      protocol_version: 1,
      initialize_timeout: @startup_timeout,
      pending_request_timeout: protocol_timeout(state.request.turn_runtime_timeout_ms),
      handler_request_timeout: protocol_timeout(state.request.approval_timeout_ms)
    )
  end

  defp initialize_session(client, request, state) do
    with {:ok, result} <- open_session(client, request),
         {:ok, provider_session_id} <- provider_session_id(result, request) do
      {:reply, {:ok, provider_session_id}, %{state | client: client, provider_session_id: provider_session_id}}
    else
      {:error, reason} ->
        stop_client(client)
        {:reply, {:error, reason}, state}
    end
  end

  defp open_session(client, request) do
    options = [mcp_servers: mcp_servers(request.mcp_config)]

    if is_binary(request.provider_session_id) do
      Client.load_session(client, request.provider_session_id, request.cwd, options)
    else
      Client.new_session(client, request.cwd, options)
    end
  end

  defp provider_session_id(result, request) do
    case result["sessionId"] || result["session_id"] || request.provider_session_id do
      provider_session_id when is_binary(provider_session_id) -> {:ok, provider_session_id}
      _invalid -> {:error, {:invalid_session_response, result}}
    end
  end

  defp finish_prompt(state, turn_id, {:ok, result}) do
    type = if result["stopReason"] == "cancelled", do: :turn_interrupted, else: :turn_completed
    emit(state, type, %{"stop_reason" => result["stopReason"]}, turn_id: turn_id)
    deny_pending_approvals(state)
  end

  defp finish_prompt(state, turn_id, {:error, reason}) do
    emit(state, :turn_failed, %{"error" => inspect(reason)}, turn_id: turn_id)
    deny_pending_approvals(state)
  end

  defp map_update(%{"sessionUpdate" => type} = update) do
    case type do
      "agent_message_chunk" -> text_event(:output_text_delta, update)
      "agent_thought_chunk" -> text_event(:thinking_delta, update)
      "tool_call" -> [event(:tool_call, update)]
      "tool_call_update" -> [event(:tool_result, update)]
      "plan" -> [event(:plan_updated, update)]
      type when type in ["usage", "usage_update"] -> [event(:usage, Map.drop(update, ["sessionUpdate"]))]
      _other -> [event(:provider_event, %{"kind" => "acp_update", "update" => update})]
    end
  end

  defp map_update(update), do: [event(:provider_event, %{"kind" => "acp_update", "update" => update})]

  defp text_event(type, update) do
    content = update["content"] || %{}
    text = content["text"] || update["text"]
    if is_binary(text), do: [event(type, %{"text" => text})], else: [event(:provider_event, update)]
  end

  defp event(type, payload), do: Event.new!(type: type, provider: :acp, payload: payload, raw: payload)

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

  defp permission_payload(tool_call, options), do: %{"tool_call" => tool_call, "options" => options}

  defp permission_outcome(options, response) do
    case select_permission_option(options, response) do
      nil -> %{"outcome" => "cancelled"}
      option -> %{"outcome" => "selected", "optionId" => option["optionId"] || option["option_id"]}
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
    Enum.each(state.approvals, fn {_request_id, approval} ->
      send(approval.handler, {
        :jido_harness_approval_response,
        approval.ref,
        %{"outcome" => "cancelled"}
      })
    end)

    %{state | approvals: %{}}
  end

  defp process_spec(request, context) do
    cli_path = option(request.provider_options, :cli_path)

    with {:ok, executable, argv, env} <- command(context.provider, cli_path, context) do
      {:ok,
       %{
         executable: executable,
         argv: argv,
         cwd: request.cwd,
         env: context.config |> configured_env() |> Map.merge(env) |> Map.merge(request.env),
         env_mode: request.env_mode,
         stdin: true,
         pty: false,
         runtime_timeout_ms: :infinity,
         idle_timeout_ms: :infinity,
         metadata: %{session_id: context.session_id, provider: context.provider, transport: :acp}
       }}
    end
  end

  defp command(:kimi, cli_path, context),
    do: {:ok, cli_path || configured_cli(context, "kimi"), ["acp"], %{"KIMI_CODE_NO_AUTO_UPDATE" => "1"}}

  defp command(:opencode, cli_path, context),
    do: {:ok, cli_path || configured_cli(context, "opencode"), ["acp"], %{}}

  defp command(provider, _cli_path, _context), do: {:error, {:unsupported_acp_provider, provider}}

  defp configured_cli(context, default) do
    context.config[:cli_path] || context.config["cli_path"] || default
  end

  defp configured_env(config), do: config[:env] || config["env"] || %{}
  defp option(options, key), do: Map.get(options, key) || Map.get(options, Atom.to_string(key))
  defp mcp_servers(nil), do: []
  defp mcp_servers(value) when is_list(value), do: value
  defp mcp_servers(value) when is_map(value), do: Map.values(value)
  defp mcp_servers(_value), do: []

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

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp file_uri(path) do
    path = Path.expand(path)
    "file://" <> URI.encode(path)
  end

  defp protocol_timeout(:infinity), do: @maximum_protocol_timeout

  defp protocol_timeout(timeout) when is_integer(timeout) do
    min(timeout + @protocol_timeout_margin, @maximum_protocol_timeout)
  end

  defp stop_prompt_task(nil), do: :ok
  defp stop_prompt_task(task), do: Task.shutdown(task, 1_000)

  defp stop_client(client), do: stop_client(client, nil)
  defp stop_client(nil, _provider_session_id), do: :ok

  defp stop_client(client, provider_session_id) when is_pid(client) do
    if Process.alive?(client) do
      if is_binary(provider_session_id), do: safe_end_session(client, provider_session_id)
      _ = Client.disconnect(client)
      GenServer.stop(client, :normal, 5_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp safe_end_session(client, provider_session_id) do
    _ = Client.end_session(client, provider_session_id)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
