defmodule Jido.Harness.ACPProviderTest do
  use ExUnit.Case, async: false

  setup do
    acp_fixture = Jido.Harness.TestHelpers.fixture_path("fake_acp_cli.py")
    original = Application.get_env(:jido_harness, :provider_config, %{})

    provider_config =
      [:amp, :claude, :codex, :gemini, :grok, :zai, :opencode]
      |> Map.new(&{&1, %{acp_path: acp_fixture}})

    Application.put_env(:jido_harness, :provider_config, Map.merge(original, provider_config))

    on_exit(fn ->
      Jido.Harness.TestHelpers.cleanup_runs()
      Jido.Harness.TestHelpers.cleanup_sessions()
      Application.put_env(:jido_harness, :provider_config, original)
    end)

    :ok
  end

  test "OpenCode resumes finite runs through ACP session loading" do
    assert {:ok, first} = Jido.Harness.run(:opencode, "first", await_timeout: 5_000)

    assert {:ok, second} =
             Jido.Harness.run(:opencode, "second", provider_session_id: first.provider_session_id, await_timeout: 5_000)

    assert second.status == :completed
    assert second.provider_session_id == first.provider_session_id

    assert {:ok, loaded} =
             Jido.Harness.run(:opencode, "loaded", provider_session_id: "saved-opencode-session", await_timeout: 5_000)

    assert loaded.provider_session_id == "saved-opencode-session"
  end

  test "normalized output retains unknown fields from the ExMCP update" do
    assert {:ok, result} = Jido.Harness.run(:grok, "fixture", await_timeout: 5_000)
    event = Enum.find(result.events, &(&1.type == :output_text_delta))
    assert event.payload == %{"text" => "fixture-ok"}
    assert event.raw["sessionUpdate"] == "agent_message_chunk"
    assert event.raw["providerExtension"] == %{"trace" => "fixture-trace"}
  end

  test "all finite provider runs use the same ACP interface" do
    Enum.each([:amp, :claude, :codex, :gemini, :grok, :zai], fn provider ->
      assert {:ok, run_id} = Jido.Harness.Run.start(provider, %{prompt: "fixture"})
      assert {:ok, result} = Jido.Harness.Run.await(run_id, 5_000)
      assert result.status == :completed
      assert result.text == "fixture-ok"
      assert result.provider_session_id == "acp-fixture-session"
      assert result.usage == %{"size" => 10, "used" => 3}
      assert Enum.any?(result.events, &match?(%{type: :provider_event, payload: %{"kind" => "acp_session_ready"}}, &1))
    end)
  end

  test "stateful sessions use the same ACP interface as finite runs" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:gemini)
    assert {:ok, first_turn} = Jido.Harness.Session.send_message(session_id, "first")
    assert {:ok, first} = Jido.Harness.Session.await(session_id, first_turn, 5_000)
    assert first.status == :completed
    assert first.provider_session_id == "acp-fixture-session"

    assert {:ok, second_turn} = Jido.Harness.Session.send_message(session_id, "second")
    assert {:ok, second} = Jido.Harness.Session.await(session_id, second_turn, 5_000)
    assert second.status == :completed
    assert second.provider_session_id == "acp-fixture-session"
  end

  test "a native ACP provider has one terminal run event" do
    assert {:ok, run_id} = Jido.Harness.Run.start(:grok, %{prompt: "fixture"})
    assert {:ok, result} = Jido.Harness.Run.await(run_id, 5_000)

    assert result.status == :completed
    assert result.text == "fixture-ok"
    assert result.error == nil

    assert {:ok, events} = Jido.Harness.Run.replay(run_id, limit: 100)

    refute Enum.any?(events, &(&1.type == :run_failed))
    assert Enum.count(events, &Jido.Harness.Event.run_terminal?/1) == 1
    assert List.last(events).type == :run_completed
  end
end
