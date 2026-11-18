if Code.ensure_loaded?(Jido.Agent.Extension) do
  defmodule Jido.Harness.Plugin.Runtime do
    @moduledoc false
    use GenServer

    alias Jido.Harness.{Error, Event, ID, Session, SessionInfo, TurnResult}
    alias Jido.{AgentServer, Signal}

    @poll_ms 75
    @recent_limit 256

    def start_link(args), do: GenServer.start_link(__MODULE__, args)
    def enqueue(runtime, command), do: GenServer.call(runtime, {:enqueue, command})

    @impl true
    def init({agent, request}) do
      {:ok,
       %{
         agent_monitor: Process.monitor(agent),
         request: request,
         task: nil,
         request_id: nil,
         poll: nil,
         poll_due?: false,
         queue: :queue.new(),
         queued_bytes: 0,
         session: %{
           agent: agent,
           id: nil,
           cursor: 0,
           turns: %{},
           approvals: %{},
           approval_limit: request.max_pending_approvals,
           recent: [],
           replay_gap?: false
         }
       }}
    end

    @impl true
    def handle_call({:enqueue, command}, _from, state) do
      bytes = :erlang.external_size(command)
      limit = state.request

      if :queue.len(state.queue) < limit.max_queued_turns and state.queued_bytes + bytes <= limit.max_queued_bytes do
        state = %{state | queue: :queue.in({command, bytes}, state.queue), queued_bytes: state.queued_bytes + bytes}
        {:reply, :ok, drive(state)}
      else
        reject(state.session, elem(command, 1), :queue_full)
        {:reply, :ok, state}
      end
    end

    @impl true
    def handle_info({ref, {:startup_failed, session}}, %{task: %{ref: ref}} = state) do
      Process.demonitor(ref, [:flush])
      reject_queue(state, :session_start_failed)
      {:noreply, %{state | task: nil, request_id: nil, session: session, queue: :queue.new(), queued_bytes: 0}}
    end

    def handle_info({ref, session}, %{task: %{ref: ref}} = state) do
      Process.demonitor(ref, [:flush])
      state = %{state | task: nil, request_id: nil, session: session}
      {:noreply, state |> schedule_poll() |> drive()}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{agent_monitor: ref} = state) do
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state) do
      if state.request_id, do: reject(state.session, state.request_id, :outcome_unknown)
      reject_queue(state, :operation_failed)
      {:stop, :harness_operation_failed, %{state | session: reset_session(state.session)}}
    end

    def handle_info(:poll, state), do: {:noreply, drive(%{state | poll: nil, poll_due?: true})}

    defp drive(%{task: %Task{}} = state), do: state

    defp drive(%{poll_due?: true, session: %{id: id}} = state) when is_binary(id) do
      start_task(%{state | poll_due?: false}, &poll/1)
    end

    defp drive(state) do
      case :queue.out(state.queue) do
        {{:value, {command, bytes}}, queue} ->
          owner = self()
          request = state.request
          state = %{state | queue: queue, queued_bytes: state.queued_bytes - bytes, poll_due?: false}
          start_task(%{state | request_id: elem(command, 1)}, &execute(&1, command, request, owner))

        {:empty, _queue} ->
          state
      end
    end

    defp start_task(state, work) do
      session = state.session
      task = Task.Supervisor.async_nolink(Jido.Harness.SessionTaskSupervisor, fn -> work.(session) end)
      %{state | task: task}
    end

    defp schedule_poll(%{session: %{id: id}, poll: nil, poll_due?: false} = state) when is_binary(id) do
      %{state | poll: Process.send_after(self(), :poll, @poll_ms)}
    end

    defp schedule_poll(state), do: state

    defp execute(session, {:prompt, request_id, text}, request, owner) do
      cond do
        request_id in session.recent or request_id in Map.values(session.turns) ->
          reject(session, request_id, :duplicate_request)
          session

        map_size(session.turns) > request.max_queued_turns ->
          reject(session, request_id, :queue_full)
          session

        true ->
          open_and_prompt(session, request_id, text, request, owner)
      end
    end

    defp execute(session, {:interrupt, request_id, turn_id}, _request, _owner) do
      outcome =
        if Map.has_key?(session.turns, turn_id),
          do: Session.interrupt(session.id, turn_id),
          else: {:error, :no_active_turn}

      report_control_error(session, request_id, outcome)
      session
    end

    defp execute(session, {:respond_approval, request_id, approval_id, decision}, _request, _owner) do
      case Map.fetch(session.approvals, approval_id) do
        {:ok, %{allow_once?: false}} when decision == :approve ->
          reject(session, request_id, :approval_scope_unsupported)
          session

        {:ok, %{provider_id: provider_id}} ->
          response = %{decision: decision, scope: :once, strict_scope: true}
          report_control_error(session, request_id, Session.respond_approval(session.id, provider_id, response))
          %{session | approvals: Map.delete(session.approvals, approval_id)}

        :error ->
          reject(session, request_id, :stale_approval)
          session
      end
    end

    defp open_and_prompt(session, request_id, text, request, owner) do
      case open(session, request, owner) do
        {:ok, session} ->
          case Session.follow_up(session.id, text) do
            {:ok, turn_id} ->
              emit(session, "turn.accepted", %{"request_id" => request_id, "turn_id" => turn_id})
              %{session | turns: Map.put(session.turns, turn_id, request_id)}

            {:error, reason} ->
              reject(session, request_id, reason)
              session
          end

        {:error, reason} ->
          reject(session, request_id, reason)
          {:startup_failed, session}
      end
    end

    defp open(%{id: id} = session, _request, _owner) when is_binary(id), do: {:ok, session}

    defp open(session, request, owner) do
      with {:ok, id} <- Session.start(request.provider, request, owner: owner),
           {:ok, info} <- Session.info(id),
           false <- SessionInfo.terminal?(info) do
        {:ok, %{session | id: id}}
      else
        true -> {:error, :session_start_failed}
        {:error, reason} -> {:error, reason}
      end
    end

    defp poll(session) do
      case Session.replay_page(session.id, cursor: session.cursor, limit: 64, max_bytes: 262_144) do
        {:ok, page} ->
          session = page.records |> coalesce_deltas() |> Enum.reduce(session, &relay/2)
          advance_cursor(session, page)

        {:error, :not_found} ->
          reset_session(session)

        {:error, _reason} ->
          exit(:harness_replay_failed)
      end
    end

    defp advance_cursor(%{id: nil} = session, _page), do: session

    defp advance_cursor(session, page) do
      gap? = session.replay_gap? or page.gaps != []
      session = %{session | cursor: page.next_cursor, replay_gap?: gap?}

      if gap? and page.next_cursor == page.latest_sequence do
        session = recover_results(%{session | replay_gap?: false})

        case Session.info(session.id) do
          {:ok, info} ->
            session = if info.pending_approvals == 0, do: %{session | approvals: %{}}, else: session
            if SessionInfo.terminal?(info), do: reset_session(session), else: session

          {:error, :not_found} ->
            reset_session(session)

          {:error, _reason} ->
            exit(:harness_session_info_failed)
        end
      else
        session
      end
    end

    defp coalesce_deltas(records) do
      records
      |> Enum.chunk_by(fn
        %Event{type: :output_text_delta, turn_id: turn_id} -> {:delta, turn_id}
        %Event{sequence: sequence} -> sequence
      end)
      |> Enum.map(fn
        [record] ->
          record

        deltas ->
          last = List.last(deltas)
          %{last | payload: %{"text" => Enum.map_join(deltas, & &1.payload["text"])}}
      end)
    end

    defp relay(%Event{type: :output_text_delta, turn_id: turn_id} = record, session) do
      if request_id = session.turns[turn_id] do
        emit(session, "turn.delta", %{
          "request_id" => request_id,
          "turn_id" => turn_id,
          "sequence" => record.sequence,
          "text" => record.payload["text"]
        })
      end

      session
    end

    defp relay(%Event{type: type, turn_id: turn_id}, session)
         when type in [:turn_completed, :turn_failed, :turn_interrupted] do
      if Map.has_key?(session.turns, turn_id), do: finish(session, turn_id, result(session, turn_id)), else: session
    end

    defp relay(%Event{type: :approval_requested, request_id: provider_id} = record, session)
         when map_size(session.approvals) < session.approval_limit do
      approval_id = ID.generate("approval")
      turn_id = record.turn_id
      allow_once? = Enum.any?(record.payload["options"] || [], &(&1["kind"] == "allow_once"))
      approval = %{provider_id: provider_id, allow_once?: allow_once?, turn_id: turn_id}
      tool_kind = record.payload["tool_call"]["kind"]

      emit(session, "approval.requested", %{
        "approval_id" => approval_id,
        "summary" => approval_summary(tool_kind),
        "can_approve_once" => allow_once?,
        "turn_id" => turn_id,
        "request_id" => session.turns[turn_id]
      })

      %{session | approvals: Map.put(session.approvals, approval_id, approval)}
    end

    defp relay(%Event{type: :approval_resolved, request_id: provider_id}, session) do
      %{
        session
        | approvals: Map.reject(session.approvals, fn {_id, approval} -> approval.provider_id == provider_id end)
      }
    end

    defp relay(%Event{type: type}, session) when type in [:session_closed, :session_cancelled, :session_failed] do
      session |> recover_results() |> reset_session()
    end

    defp relay(_record, session), do: session

    defp approval_summary(kind)
         when kind in ["read", "edit", "delete", "move", "search", "execute", "fetch", "switch_mode"],
         do: "The coding agent requested permission for a tool of kind " <> kind <> "."

    defp approval_summary(_kind), do: "The coding agent requested tool permission."

    defp recover_results(session) do
      Enum.reduce(Map.keys(session.turns), session, fn turn_id, acc ->
        case result(acc, turn_id) do
          {:error, :timeout} -> acc
          outcome -> finish(acc, turn_id, outcome)
        end
      end)
    end

    defp result(session, turn_id), do: Session.await(session.id, turn_id, 0)

    defp finish(session, turn_id, outcome) do
      {request_id, turns} = Map.pop(session.turns, turn_id)
      data = %{"request_id" => request_id, "turn_id" => turn_id}

      payload =
        case outcome do
          {:ok, %TurnResult{} = result} ->
            %{"status" => Atom.to_string(result.status), "text" => result.text, "truncated" => result.text_truncated?}
            |> add_error(result.error)

          {:error, _reason} ->
            %{"status" => "failed", "code" => "result_unavailable"}
        end

      emit(session, "turn.finished", Map.merge(data, payload))
      approvals = Map.reject(session.approvals, fn {_id, approval} -> approval.turn_id == turn_id end)
      %{session | turns: turns, approvals: approvals, recent: Enum.take([request_id | session.recent], @recent_limit)}
    end

    defp reset_session(session) do
      session =
        Enum.reduce(Map.keys(session.turns), session, fn turn_id, acc ->
          finish(acc, turn_id, {:error, :result_unavailable})
        end)

      %{session | id: nil, cursor: 0, approvals: %{}, replay_gap?: false}
    end

    defp add_error(data, nil), do: data
    defp add_error(data, error), do: Map.put(data, "code", error_code(error))

    defp report_control_error(_session, _request_id, :ok), do: :ok
    defp report_control_error(session, request_id, {:error, reason}), do: reject(session, request_id, reason)

    defp reject_queue(state, reason) do
      Enum.each(:queue.to_list(state.queue), fn {command, _bytes} ->
        reject(state.session, elem(command, 1), reason)
      end)
    end

    defp reject(session, request_id, reason) do
      emit(session, "error.command", %{"request_id" => request_id, "code" => error_code(reason)})
    end

    defp error_code(%Error{category: category}), do: error_code(category)
    defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp error_code(_reason), do: "provider_failure"

    defp emit(session, type, data) do
      AgentServer.cast(session.agent, Signal.new!("jido.harness." <> type, data, source: "/harness/plugin"))
    end
  end
end
