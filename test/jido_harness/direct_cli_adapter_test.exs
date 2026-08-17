defmodule Jido.Harness.DirectCLIAdapterTest do
  use ExUnit.Case, async: false

  setup do
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_stream_cli.exs")
    original = Application.get_env(:jido_harness, :provider_config, %{})

    provider_config =
      [:amp, :claude, :codex, :gemini, :grok, :zai]
      |> Map.new(&{&1, %{cli_path: fixture}})

    Application.put_env(:jido_harness, :provider_config, Map.merge(original, provider_config))

    on_exit(fn ->
      Jido.Harness.TestHelpers.cleanup_runs()
      Jido.Harness.TestHelpers.cleanup_sessions()
      Application.put_env(:jido_harness, :provider_config, original)
    end)

    :ok
  end

  test "direct CLI providers stream normalized results through managed processes" do
    expected = %{
      amp: {"amp-ok", "amp-fixture-session"},
      claude: {"claude-ok", "claude-fixture-session"},
      codex: {"codex-ok", "codex-fixture-session"},
      gemini: {"gemini-ok", "gemini-fixture-session"},
      grok: {"grok-ok", "grok-fixture-session"},
      zai: {"claude-ok", "claude-fixture-session"}
    }

    Enum.each(expected, fn {provider, {text, provider_session_id}} ->
      assert {:ok, run_id} = Jido.Harness.Run.start(provider, %{prompt: "fixture"})
      assert {:ok, result} = Jido.Harness.Run.await(run_id, 5_000)
      assert result.status == :completed
      assert result.text == text
      assert result.provider_session_id == provider_session_id
      assert result.usage["total_tokens"] == 3
    end)
  end

  test "managed resume sessions reuse provider session identifiers" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:gemini)
    assert {:ok, first_turn} = Jido.Harness.Session.send_message(session_id, "first")
    assert {:ok, first} = Jido.Harness.Session.await(session_id, first_turn, 5_000)
    assert first.status == :completed
    assert first.provider_session_id == "gemini-fixture-session"

    assert {:ok, second_turn} = Jido.Harness.Session.send_message(session_id, "second")
    assert {:ok, second} = Jido.Harness.Session.await(session_id, second_turn, 5_000)
    assert second.status == :completed
    assert second.provider_session_id == "gemini-fixture-session"
  end

  test "Grok completes after a recovered tool error" do
    assert {:ok, run_id} = Jido.Harness.Run.start(:grok, %{prompt: "fixture"})
    assert {:ok, result} = Jido.Harness.Run.await(run_id, 5_000)

    assert result.status == :completed
    assert result.text == "grok-ok"
    assert result.error == nil

    assert {:ok, events} = Jido.Harness.Run.replay(run_id, limit: 100)

    assert Enum.any?(events, fn
             %{type: :tool_result, payload: %{"call_id" => "call-read", "is_error" => true}} -> true
             _event -> false
           end)

    refute Enum.any?(events, &(&1.type == :run_failed))
    assert Enum.count(events, &Jido.Harness.Event.run_terminal?/1) == 1
    assert List.last(events).type == :run_completed
  end
end
