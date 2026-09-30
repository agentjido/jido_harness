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

  setup context do
    options = [
      process_manager: ControlledProcessManager,
      process_owner: self(),
      process_spec: %{env: context[:env] || %{}},
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
    assert {:error, {:process_stopped, :failed, diagnostics}} = Bridge.receive_message(bridge)
    assert diagnostics["details"] == details
    assert_receive {:acp_process_stopped, :failed, ^diagnostics}
    assert {:error, {:process_stopped, :failed, ^diagnostics}} = Bridge.receive_message(bridge)
    refute_received {:acp_process_stopped, _, _}
  end

  test "a waiting receiver gets the same stop reason and listener details", %{bridge: bridge, reader: reader} do
    receiver = Task.async(fn -> Bridge.receive_message(bridge) end)
    await(fn -> match?(%{waiter: {_, _}}, :sys.get_state(bridge)) end)
    send(reader, {:process_events, [event(:timed_out, "fixture deadline")]})

    assert {:error, {:process_stopped, :timed_out, diagnostics}} = Task.await(receiver)
    assert diagnostics["details"] == "fixture deadline"
    assert_receive {:acp_process_stopped, :timed_out, ^diagnostics}
    assert {:error, {:process_stopped, :timed_out, ^diagnostics}} = Bridge.receive_message(bridge)
    refute_received {:acp_process_stopped, _, _}
  end

  test "failure diagnostics retain a bounded stderr tail", %{bridge: bridge, reader: reader} do
    send(
      reader,
      {:process_events,
       [event(:stderr, String.duplicate("x", 8_000) <> "last error"), event(:failed, %{"exit_status" => 1})]}
    )

    await(fn -> not Bridge.connected?(bridge) end)
    assert {:error, {:process_stopped, :failed, diagnostics}} = Bridge.receive_message(bridge)
    assert byte_size(diagnostics["stderr"]) <= 4_096
    assert diagnostics["stderr_truncated"]
    assert String.ends_with?(diagnostics["stderr"], "last error")
  end

  @tag env: %{"SECRET_TOKEN" => "abcd"}
  test "redaction does not expand diagnostics beyond the stderr limit", %{bridge: bridge, reader: reader} do
    send(reader, {:process_events, [event(:stderr, String.duplicate("abcd", 1_024)), event(:failed, %{})]})
    await(fn -> not Bridge.connected?(bridge) end)
    assert {:error, {:process_stopped, :failed, diagnostics}} = Bridge.receive_message(bridge)
    assert byte_size(diagnostics["stderr"]) <= 4_096
    assert diagnostics["stderr_truncated"]
    refute diagnostics["stderr"] =~ "abcd"
  end

  @tag env: %{"SECRET_TOKEN" => "token1234567890"}
  test "stderr truncation does not expose a clipped secret", %{bridge: bridge, reader: reader} do
    data = "token1234567890" <> String.duplicate("x", 4_090)
    send(reader, {:process_events, [event(:stderr, data), event(:failed, %{})]})
    await(fn -> not Bridge.connected?(bridge) end)
    assert {:error, {:process_stopped, :failed, diagnostics}} = Bridge.receive_message(bridge)
    refute diagnostics["stderr"] =~ "67890"
    assert byte_size(diagnostics["stderr"]) <= 4_096
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
