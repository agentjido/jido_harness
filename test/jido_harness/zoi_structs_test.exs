defmodule Jido.Harness.ZoiStructsTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{
    AdapterSpec,
    ApprovalResponse,
    Buffer,
    Capabilities,
    Error,
    Event,
    InteractionCapabilities,
    Journal,
    ProcessEvent,
    ProcessInfo,
    ProcessSpec,
    ProviderStatus,
    RunInfo,
    RunRequest,
    RunResult,
    SessionInfo,
    SessionRequest,
    SessionTransportSpec,
    TextTail,
    TurnRequest,
    TurnResult
  }

  @struct_modules [
    AdapterSpec,
    ApprovalResponse,
    Buffer,
    Capabilities,
    Error,
    Event,
    InteractionCapabilities,
    Journal,
    ProcessEvent,
    ProcessInfo,
    ProcessSpec,
    ProviderStatus,
    RunInfo,
    RunRequest,
    RunResult,
    SessionInfo,
    SessionRequest,
    SessionTransportSpec,
    TextTail,
    TurnRequest,
    TurnResult
  ]

  test "every package struct is backed by an exported Zoi struct schema" do
    Enum.each(@struct_modules, fn module ->
      assert Code.ensure_loaded?(module), "#{inspect(module)} is not loadable"
      assert function_exported?(module, :schema, 0), "#{inspect(module)} does not export schema/0"
      assert module.schema().__struct__ == Zoi.Types.Struct
    end)
  end

  test "public result and information structs validate through their schemas" do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    event = Event.new!(type: :run_completed, provider: :test)

    assert {:ok, %ProcessEvent{}} =
             ProcessEvent.new(process_id: "process_1", sequence: 1, timestamp: timestamp, type: :started)

    assert {:ok, %ProcessInfo{}} =
             ProcessInfo.new(process_id: "process_1", state: :running, started_at: timestamp)

    assert {:ok, %ProviderStatus{}} = ProviderStatus.new(provider: :test)
    assert {:ok, %RunInfo{}} = RunInfo.new(run_id: "run_1", provider: :test, state: :running, started_at: timestamp)
    assert {:ok, %RunResult{}} = RunResult.new(run_id: "run_1", provider: :test, status: :completed, events: [event])

    assert {:ok, %SessionInfo{}} =
             SessionInfo.new(session_id: "session_1", provider: :test, state: :idle, started_at: timestamp)

    assert {:ok, %TurnResult{}} =
             TurnResult.new(session_id: "session_1", turn_id: "turn_1", provider: :test, status: :completed)
  end

  test "adapter metadata rejects contradictory transport declarations" do
    capabilities = InteractionCapabilities.new!(transport: :native)

    transport =
      SessionTransportSpec.new!(
        name: :native,
        adapter: Jido.Harness.SessionAdapters.Managed,
        capabilities: capabilities
      )

    assert {:error, %{category: :validation}} =
             AdapterSpec.new(
               provider: :test,
               name: "Test",
               executable: "test",
               capabilities: %Capabilities{},
               session_transports: [transport]
             )
  end
end
