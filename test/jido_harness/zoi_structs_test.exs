defmodule Jido.Harness.ZoiStructsTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{
    AdapterSpec,
    ACPAgentSpec,
    ApprovalResponse,
    Buffer,
    Capabilities,
    Error,
    Event,
    SessionCapabilities,
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
    StructuredOutput,
    TextTail,
    TurnRequest,
    TurnResult
  }

  @struct_modules [
    AdapterSpec,
    ACPAgentSpec,
    ApprovalResponse,
    Buffer,
    Capabilities,
    Error,
    Event,
    SessionCapabilities,
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
    StructuredOutput,
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

  test "adapter metadata validates one ACP agent declaration" do
    capabilities = SessionCapabilities.new!(load_session: true, multimodal: true)
    acp_agent = ACPAgentSpec.native("test", ["acp"], %{capabilities: capabilities})

    assert {:ok, %AdapterSpec{acp_agent: ^acp_agent}} =
             AdapterSpec.new(
               provider: :test,
               name: "Test",
               executable: "test",
               capabilities: %Capabilities{},
               acp_agent: acp_agent
             )
  end

  test "ACP adapter declarations require an exact package and unique options" do
    assert {:error, %Error{message: "ACP adapter source requires an exact package"}} =
             ACPAgentSpec.new(executable: "test-acp", source: :adapter, package: "test-acp")

    assert {:error, %Error{message: "ACP option names must be unique", details: %{field: :turn_options}}} =
             ACPAgentSpec.new(
               executable: "test-acp",
               source: :adapter,
               package: "test-acp@1.0.0",
               turn_options: [:attachments, :attachments]
             )
  end
end
