defmodule Jido.Harness.ACPTransportTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.ProcessEvent
  alias Jido.Harness.SessionAdapters.ACP.ExMCPTransport.Bridge

  defmodule ControlledProcessManager do
    def start_owned_process(_spec, owner), do: {:ok, owner}
    def cancel_process(_owner), do: :ok

    def stream_process(owner) do
      stream =
        Stream.resource(
          fn ->
            send(owner, {:process_reader, self()})
            :open
          end,
          fn state ->
            receive do
              {:process_events, events} -> {events, state}
            end
          end,
          fn _ -> :ok end
        )

      {:ok, stream}
    end
  end

  setup do
    options = [
      process_manager: ControlledProcessManager,
      process_owner: self(),
      process_spec: nil,
      listener: self()
    ]

    bridge = start_supervised!({Bridge, options})
    assert_receive {:process_reader, reader}
    %{bridge: bridge, reader: reader}
  end

  test "drains complete frames before reporting a stopped process once", %{bridge: bridge, reader: reader} do
    details = %{"reason" => "fixture exit"}
    send(reader, {:process_events, [event(:stdout, "first\nsecond\npartial"), event(:failed, details)]})
    await(fn -> not Bridge.connected?(bridge) end)
    refute_received {:acp_process_stopped, _, _}

    assert {:ok, "first"} = Bridge.receive_message(bridge)
    assert {:ok, "second"} = Bridge.receive_message(bridge)
    assert {:error, {:process_stopped, :failed}} = Bridge.receive_message(bridge)
    assert_receive {:acp_process_stopped, :failed, ^details}
    assert {:error, {:process_stopped, :failed}} = Bridge.receive_message(bridge)
    refute_received {:acp_process_stopped, _, _}
  end

  test "a waiting receiver gets the same stop reason and listener details", %{bridge: bridge, reader: reader} do
    receiver = Task.async(fn -> Bridge.receive_message(bridge) end)
    await(fn -> match?(%{waiter: {_, _}}, :sys.get_state(bridge)) end)
    send(reader, {:process_events, [event(:timed_out, "fixture deadline")]})

    assert {:error, {:process_stopped, :timed_out}} = Task.await(receiver)
    assert_receive {:acp_process_stopped, :timed_out, "fixture deadline"}
    assert {:error, {:process_stopped, :timed_out}} = Bridge.receive_message(bridge)
    refute_received {:acp_process_stopped, _, _}
  end

  defp event(type, data) do
    %ProcessEvent{process_id: "fixture", sequence: 1, timestamp: "2026-09-04T00:00:00Z", type: type, data: data}
  end

  defp await(condition, attempts \\ 100)
  defp await(_condition, 0), do: flunk("transport did not reach the expected state")

  defp await(condition, attempts) do
    unless condition.() do
      Process.sleep(10)
      await(condition, attempts - 1)
    end
  end
end
