defmodule Jido.Harness.ACPFrameLimitTest do
  # Not async: the limit is application configuration
  use ExUnit.Case, async: false

  alias Jido.Harness.ProcessEvent
  alias Jido.Harness.SessionAdapters.ACP.ExMCPTransport
  alias Jido.Harness.SessionAdapters.ACP.ExMCPTransport.Bridge

  defmodule ControlledProcessManager do
    def start_owned_process(_spec, owner), do: {:ok, owner}
    def cancel_process(_owner), do: :ok

    def send_input(owner, data) do
      send(owner, {:process_input, data})
      :ok
    end

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
    on_exit(fn ->
      Application.delete_env(:jido_harness, :acp_max_frame_bytes)
      Application.delete_env(:jido_harness, :acp_max_buffer_bytes)
    end)

    :ok
  end

  test "the limit is 1 MiB unless the application configures a valid one" do
    assert ExMCPTransport.max_frame_bytes() == 1_048_576

    Application.put_env(:jido_harness, :acp_max_frame_bytes, 4_000_000)
    assert ExMCPTransport.max_frame_bytes() == 4_000_000

    Application.put_env(:jido_harness, :acp_max_frame_bytes, 0)
    assert ExMCPTransport.max_frame_bytes() == 1_048_576
  end

  test "the queue limit leaves space for complete frames and validates configured values" do
    assert ExMCPTransport.max_buffer_bytes() == 4_194_304
    Application.put_env(:jido_harness, :acp_max_buffer_bytes, 8_388_608)
    assert ExMCPTransport.max_buffer_bytes() == 8_388_608
    Application.put_env(:jido_harness, :acp_max_buffer_bytes, 1)
    assert ExMCPTransport.max_buffer_bytes() == 4_194_304
    Application.put_env(:jido_harness, :acp_max_frame_bytes, 2_097_152)
    assert ExMCPTransport.max_buffer_bytes() == 8_388_608
  end

  test "a frame over the default limit stops the transport" do
    {bridge, reader} = start_bridge()
    send(reader, {:process_events, [event(String.duplicate("a", 1_048_577) <> "\n")]})

    assert {:error, {:process_stopped, :failed, :frame_too_large}} = Bridge.receive_message(bridge)
    assert_receive {:acp_process_stopped, :failed, :frame_too_large}
  end

  test "a raised limit lets the same frame through" do
    Application.put_env(:jido_harness, :acp_max_frame_bytes, 4_000_000)
    {bridge, reader} = start_bridge()
    frame = String.duplicate("a", 1_048_577)
    send(reader, {:process_events, [event(frame <> "\n")]})

    assert {:ok, ^frame} = Bridge.receive_message(bridge)
  end

  test "an oversized extension request is not written to the process" do
    Application.put_env(:jido_harness, :acp_max_frame_bytes, 256)
    {bridge, _reader} = start_bridge()

    assert {:error, :frame_too_large} =
             Bridge.extension_request(bridge, "_session/steering", %{"text" => String.duplicate("x", 256)}, 1_000)

    refute_receive {:process_input, _data}
    assert Bridge.connected?(bridge)
  end

  test "a raised limit permits an extension request larger than the default" do
    Application.put_env(:jido_harness, :acp_max_frame_bytes, 4_000_000)
    {bridge, reader} = start_bridge()
    text = String.duplicate("x", 1_048_577)
    request = Task.async(fn -> Bridge.extension_request(bridge, "_session/steering", %{"text" => text}, 2_000) end)

    assert_receive {:process_input, data}, 1_000
    assert %{"id" => id, "params" => %{"text" => ^text}} = Jason.decode!(data)
    response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"outcome" => "injected"}})
    send(reader, {:process_events, [event(response <> "\n")]})
    assert {:ok, %{"outcome" => "injected"}} = Task.await(request)
  end

  defp start_bridge do
    options = [
      process_manager: ControlledProcessManager,
      process_owner: self(),
      process_spec: nil,
      listener: self()
    ]

    bridge = start_supervised!({Bridge, options})
    assert_receive {:process_reader, reader}
    {bridge, reader}
  end

  defp event(data) do
    %ProcessEvent{process_id: "fixture", sequence: 1, timestamp: "2026-09-04T00:00:00Z", type: :stdout, data: data}
  end
end
