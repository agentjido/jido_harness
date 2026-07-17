defmodule Jido.Harness.SessionAdapters.CodexAppServerTransport do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Adapters.Helpers, Adapters.SDKMapper, ApprovalResponse, Error, Event, SessionRequest, TurnRequest}

  def start_link({request, context}), do: GenServer.start_link(__MODULE__, {request, context})

  @impl true
  def init({%SessionRequest{} = request, context}) do
    Process.flag(:trap_exit, true)

    with {:ok, options} <- codex_options(request, context.config),
         {:ok, conn} <- Codex.AppServer.connect(options, client_name: "jido_harness", client_title: "Jido Harness"),
         :ok <- Codex.AppServer.subscribe(conn),
         {:ok, thread} <- thread(request, options, conn) do
      {:ok,
       %{
         request: request,
         context: context,
         owner: context.owner,
         conn: conn,
         thread: thread,
         active: nil,
         task: nil,
         approval_ids: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  rescue
    exception -> {:stop, exception}
  end

  @impl true
  def handle_call({:send, _request, _turn_id}, _from, %{active: active} = state) when not is_nil(active),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:send, %TurnRequest{} = turn, turn_id}, _from, state) do
    input = codex_input(turn, state.request.cwd)

    turn_options =
      %{
        timeout_ms: timeout(state.request.turn_runtime_timeout_ms),
        completion_timeout_ms: timeout(state.request.turn_runtime_timeout_ms),
        effort: turn.reasoning_effort || state.request.reasoning_effort,
        output_schema: turn.output_schema
      }
      |> compact()

    case Codex.Thread.run_streamed(state.thread, input, turn_options) do
      {:ok, streaming} ->
        parent = self()

        task =
          Task.Supervisor.async_nolink(Jido.Harness.SessionTaskSupervisor, fn ->
            consume(parent, state.owner, streaming, turn_id)
          end)

        active = %{turn_id: turn_id, provider_turn_id: nil, streaming: streaming}
        {:reply, :ok, %{state | active: active, task: task}}

      {:error, reason} ->
        {:reply, {:error, Error.execution("Codex app-server could not start turn", provider: :codex, cause: reason)},
         state}
    end
  end

  def handle_call({:interrupt, requested}, _from, %{active: active} = state)
      when requested in [:active, active.turn_id] do
    :ok = Codex.RunResultStreaming.cancel(active.streaming, :immediate)
    if state.task, do: Task.shutdown(state.task, 5_000)
    {:reply, :ok, %{state | active: nil, task: nil}}
  end

  def handle_call({:interrupt, _turn_id}, _from, state), do: {:reply, {:error, :not_active}, state}

  def handle_call({:steer, _turn, _request_id}, _from, %{active: %{provider_turn_id: nil}} = state),
    do: {:reply, {:error, :turn_not_started}, state}

  def handle_call({:steer, %TurnRequest{} = turn, _request_id}, _from, %{active: active} = state) do
    params = %{
      "threadId" => state.thread.thread_id,
      "turnId" => active.provider_turn_id,
      "input" => user_input(codex_input(turn, state.request.cwd))
    }

    reply =
      case Codex.AppServer.Connection.request(state.conn, "turn/steer", params, timeout_ms: 30_000) do
        {:ok, _response} -> :ok
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:respond_approval, {request_id, %ApprovalResponse{} = response}}, _from, state) do
    decision =
      case {response.decision, response.scope} do
        {:approve, :once} -> "accept"
        {:approve, :session} -> "acceptForSession"
        {:deny, _scope} -> "decline"
      end

    case Map.pop(state.approval_ids, request_id) do
      {nil, _ids} ->
        {:reply, {:error, :unknown_request}, state}

      {provider_request_id, ids} ->
        reply = Codex.AppServer.respond(state.conn, provider_request_id, %{"decision" => decision})
        {:reply, reply, %{state | approval_ids: ids}}
    end
  end

  def handle_call(:close, _from, state) do
    state = stop_active(state)
    deny_pending_approvals(state)
    _ = Codex.AppServer.unsubscribe(state.conn)
    :ok = Codex.AppServer.disconnect(state.conn)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:codex_ids, thread_id, provider_turn_id}, state) do
    thread = if is_binary(thread_id), do: %{state.thread | thread_id: thread_id}, else: state.thread

    active =
      if state.active && is_binary(provider_turn_id),
        do: %{state.active | provider_turn_id: provider_turn_id},
        else: state.active

    {:noreply, %{state | thread: thread, active: active}}
  end

  def handle_info({:codex_request, id, method, params}, state)
      when method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] do
    payload = %{
      "kind" => approval_kind(method),
      "reason" => Map.get(params, "reason"),
      "item_id" => Map.get(params, "itemId"),
      "provider_turn_id" => Map.get(params, "turnId")
    }

    Jido.Harness.SessionAdapter.emit(
      state.owner,
      Event.new!(
        type: :approval_requested,
        provider: :codex,
        provider_session_id: state.thread.thread_id,
        request_id: to_string(id),
        payload: payload,
        raw: params
      )
    )

    {:noreply, %{state | approval_ids: Map.put(state.approval_ids, to_string(id), id)}}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    thread =
      case result do
        {:ok, thread_id} when is_binary(thread_id) -> %{state.thread | thread_id: thread_id}
        _ -> state.thread
      end

    {:noreply, %{state | thread: thread, active: nil, task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}, active: active} = state) do
    Jido.Harness.SessionAdapter.emit(
      state.owner,
      Event.new!(
        type: :turn_failed,
        provider: :codex,
        provider_session_id: state.thread.thread_id,
        turn_id: active.turn_id,
        payload: %{"error" => "Codex app-server stream exited: #{inspect(reason)}"}
      )
    )

    {:noreply, %{state | active: nil, task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = stop_active(state)
    if state.conn, do: Codex.AppServer.disconnect(state.conn)
    :ok
  rescue
    _ -> :ok
  end

  defp consume(parent, owner, streaming, harness_turn_id) do
    final =
      streaming
      |> Codex.RunResultStreaming.events()
      |> Enum.reduce(%{thread_id: nil, provider_turn_id: nil, terminal?: false}, fn raw, acc ->
        thread_id = Map.get(raw, :thread_id) || acc.thread_id
        provider_turn_id = Map.get(raw, :turn_id) || acc.provider_turn_id
        send(parent, {:codex_ids, thread_id, provider_turn_id})

        mapped =
          raw
          |> SDKMapper.codex()
          |> Enum.map(&normalize_event(&1, harness_turn_id))

        Enum.each(mapped, fn event ->
          unless event.type in [:run_started, :run_completed] do
            Jido.Harness.SessionAdapter.emit(owner, event)
          end
        end)

        terminal? = acc.terminal? or Enum.any?(mapped, &Event.turn_terminal?/1)
        %{acc | thread_id: thread_id, provider_turn_id: provider_turn_id, terminal?: terminal?}
      end)

    unless final.terminal? do
      Jido.Harness.SessionAdapter.emit(
        owner,
        Event.new!(
          type: :turn_completed,
          provider: :codex,
          provider_session_id: final.thread_id,
          turn_id: harness_turn_id,
          payload: %{}
        )
      )
    end

    {:ok, final.thread_id}
  rescue
    exception ->
      Jido.Harness.SessionAdapter.emit(
        owner,
        Event.new!(
          type: :turn_failed,
          provider: :codex,
          turn_id: harness_turn_id,
          payload: %{"error" => Exception.message(exception)}
        )
      )

      {:error, exception}
  end

  defp normalize_event(%Event{type: :run_failed} = event, turn_id),
    do: %{event | type: :turn_failed, run_id: nil, turn_id: turn_id}

  defp normalize_event(%Event{type: :run_cancelled} = event, turn_id),
    do: %{event | type: :turn_interrupted, run_id: nil, turn_id: turn_id}

  defp normalize_event(%Event{} = event, turn_id), do: %{event | run_id: nil, turn_id: turn_id}

  defp codex_options(request, config) do
    provider = Helpers.provider_options(request.provider_options, [:cli_path])

    attrs =
      %{
        codex_path_override: provider[:cli_path] || Map.get(config, :cli_path),
        model: request.model || "",
        reasoning_effort: request.reasoning_effort
      }
      |> compact()

    Codex.Options.new(attrs)
  end

  defp thread(request, options, conn) do
    thread_options =
      %{
        transport: {:app_server, conn},
        working_directory: request.cwd,
        model: request.model,
        developer_instructions: request.system_prompt,
        additional_directories: request.add_dirs || [],
        ask_for_approval: approval(request.approval_mode),
        sandbox: sandbox(request.sandbox_mode),
        stream_idle_timeout_ms: nil
      }
      |> compact()

    if request.provider_session_id do
      Codex.resume_thread(request.provider_session_id, options, thread_options)
    else
      Codex.start_thread(options, thread_options)
    end
  end

  defp codex_input(%TurnRequest{} = turn, cwd) do
    blocks =
      case turn.content do
        [_ | _] = content -> Enum.map(content, &stringify_keys/1)
        [] -> [%{"type" => "text", "text" => TurnRequest.text(turn)}]
      end

    blocks ++
      Enum.map(turn.attachments, fn path ->
        %{"type" => "local_image", "path" => Path.expand(path, cwd)}
      end)
  end

  defp user_input(input) when is_list(input) do
    Codex.AppServer.Params.user_input(input)
  end

  defp stop_active(%{active: nil} = state), do: state

  defp stop_active(state) do
    :ok = Codex.RunResultStreaming.cancel(state.active.streaming, :immediate)
    if state.task, do: Task.shutdown(state.task, 5_000)
    %{state | active: nil, task: nil}
  end

  defp deny_pending_approvals(state) do
    Enum.each(state.approval_ids, fn {_request_id, provider_request_id} ->
      _ = Codex.AppServer.respond(state.conn, provider_request_id, %{"decision" => "decline"})
    end)

    :ok
  end

  defp timeout(:infinity), do: Helpers.sdk_timeout(:infinity)
  defp timeout(value), do: value
  defp approval(:default), do: nil
  defp approval(:prompt), do: :on_request
  defp approval(:auto_edit), do: :on_failure
  defp approval(:auto_approve), do: :never
  defp sandbox(:default), do: :default
  defp sandbox(:read_only), do: :read_only
  defp sandbox(:workspace_write), do: :workspace_write
  defp sandbox(:unrestricted), do: :danger_full_access
  defp approval_kind("item/commandExecution/requestApproval"), do: "command_execution"
  defp approval_kind(_method), do: "file_change"

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
