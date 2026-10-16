defmodule Jido.Harness.SessionLimitsTest do
  use ExUnit.Case, async: true
  alias Jido.Harness.{Buffer, Event, MemoryHarness, SessionRequest, SessionWorker, TurnRequest}
  alias Jido.Harness.Session.{ActiveTurn, Lifecycle}

  test "all memory limits reject invalid values and accept string keys" do
    for key <- [:max_queued_turns, :max_queued_bytes, :max_retained_turns, :max_result_bytes, :max_pending_approvals] do
      for invalid <- [0, -1, "10", nil, :infinity] do
        assert {:error, _} = SessionRequest.new(%{key => invalid})
      end

      assert {:ok, request} = SessionRequest.new(%{Atom.to_string(key) => 10})
      assert Map.fetch!(request, key) == 10
    end
  end

  test "harness limits do not require provider capabilities" do
    request = SessionRequest.new!(%{max_queued_turns: 3, max_retained_turns: 5})
    spec = Jido.Harness.TestAdapter.spec()
    assert :ok = Jido.Harness.SessionManager.validate_request(request, spec, spec.acp_agent)
  end

  test "turn count and byte budgets reject follow-ups without changing state" do
    state = MemoryHarness.state(%{max_queued_turns: 1})
    assert {:reply, {:ok, _id}, state} = SessionWorker.handle_call({:follow_up, "one"}, nil, state)
    assert state.queued_bytes == :erlang.external_size(TurnRequest.new!("one"))
    assert {:reply, {:error, :queue_full}, ^state} = SessionWorker.handle_call({:follow_up, "two"}, nil, state)

    bytes_state = MemoryHarness.state(%{max_queued_bytes: 100})

    assert {:reply, {:error, :queue_full}, ^bytes_state} =
             SessionWorker.handle_call({:follow_up, String.duplicate("x", 101)}, nil, bytes_state)
  end

  test "completed results and known turn IDs expire together" do
    state = Enum.reduce(1..100, MemoryHarness.state(%{max_retained_turns: 3}), &MemoryHarness.finish_turn(&2, "t#{&1}"))
    assert Map.keys(state.results) |> Enum.sort() == ["t100", "t98", "t99"]
    assert state.known_turns == MapSet.new(Map.keys(state.results))
    assert {:reply, {:error, :not_found}, ^state} = SessionWorker.handle_call({:turn_result, "t1"}, nil, state)
    assert state.result_bytes == Enum.sum(Enum.map(Map.values(state.results), &:erlang.external_size/1))
  end

  test "an oversized result reaches current waiters but is not retained" do
    state = MemoryHarness.state(%{max_result_bytes: 1})
    ref = make_ref()
    state = %{state | waiters: Jido.Harness.Waiters.add(%{}, ref, {self(), ref}, "turn")}
    state = MemoryHarness.finish_turn(state, "turn")
    assert_receive {^ref, {:ok, %{turn_id: "turn", status: :completed}}}
    assert state.results == %{}
    assert state.result_bytes == 0
    assert state.known_turns == MapSet.new()
    assert state.waiters == %{}
  end

  test "expired turn events cannot change the active result or request approval" do
    state =
      MemoryHarness.state(%{max_retained_turns: 1})
      |> MemoryHarness.finish_turn("old")
      |> MemoryHarness.finish_turn("recent")

    active = ActiveTurn.new("current", TurnRequest.new!("fixture"), 1_024)
    state = %{state | active: active, status: :running}
    event = Event.new!(type: :output_text_delta, provider: :test, turn_id: "old", payload: %{"text" => "stale"})
    assert {:noreply, updated} = SessionWorker.handle_info({:session_adapter_event, event}, state)
    assert updated.active == active

    approval =
      Event.new!(type: :approval_requested, provider: :test, turn_id: "old", request_id: "old-approval", payload: %{})

    updated = Lifecycle.handle_approval_request(updated, approval)
    assert updated.pending_approvals == %{}
    assert List.last(Buffer.events(updated.buffer)).payload["kind"] == "stale_approval_denied"
  end

  test "approval admission is bounded and duplicate requests do not consume capacity" do
    state = MemoryHarness.state(%{max_pending_approvals: 1})
    first = Event.new!(type: :approval_requested, provider: :test, request_id: "first", payload: %{})
    state = Lifecycle.handle_approval_request(state, first)
    assert map_size(Lifecycle.handle_approval_request(state, first).pending_approvals) == 1
    next = %{first | request_id: "second"}
    state = Lifecycle.handle_approval_request(state, next)
    assert Map.keys(state.pending_approvals) == ["first"]
    assert List.last(Buffer.events(state.buffer)).payload["kind"] == "approval_limit_reached"
  end

  test "closing a queued session releases its byte accounting" do
    state = MemoryHarness.state()
    assert {:reply, {:ok, _id}, state} = SessionWorker.handle_call({:follow_up, "one"}, nil, state)
    state = Lifecycle.terminate_session(state, :session_closed, %{})
    assert state.queued_bytes == 0
    assert :queue.is_empty(state.queue)
  end
end
