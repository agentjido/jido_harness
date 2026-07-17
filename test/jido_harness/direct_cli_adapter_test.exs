defmodule Jido.Harness.DirectCLIAdapterTest do
  use ExUnit.Case, async: false

  setup do
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_stream_cli.exs")
    original = Application.get_env(:jido_harness, :provider_config, %{})

    provider_config =
      [:amp, :claude, :codex, :gemini, :zai]
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
      zai: {"claude-ok", "claude-fixture-session"}
    }

    Enum.each(expected, fn {provider, {text, provider_session_id}} ->
      assert {:ok, run_id} = Jido.Harness.start(provider, %{prompt: "fixture"})
      assert {:ok, result} = Jido.Harness.await(run_id, 5_000)
      assert result.status == :completed
      assert result.text == text
      assert result.provider_session_id == provider_session_id
      assert result.usage["total_tokens"] == 3
    end)
  end

  test "managed resume sessions reuse provider session identifiers" do
    assert {:ok, session_id} = Jido.Harness.open_session(:gemini)
    assert {:ok, first_turn} = Jido.Harness.send_message(session_id, "first")
    assert {:ok, first} = Jido.Harness.await_turn(session_id, first_turn, 5_000)
    assert first.status == :completed
    assert first.provider_session_id == "gemini-fixture-session"

    assert {:ok, second_turn} = Jido.Harness.send_message(session_id, "second")
    assert {:ok, second} = Jido.Harness.await_turn(session_id, second_turn, 5_000)
    assert second.status == :completed
    assert second.provider_session_id == "gemini-fixture-session"
  end
end
