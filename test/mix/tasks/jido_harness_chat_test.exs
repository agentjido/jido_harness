defmodule Mix.Tasks.JidoHarness.ChatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-chat-#{System.unique_integer([:positive])}")
    Jido.Harness.TestHelpers.configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    Mix.Task.reenable("jido_harness.chat")
    Mix.Task.reenable("app.start")
    :ok
  end

  test "parses normalized interactive options" do
    {options, "test"} =
      Mix.Tasks.JidoHarness.Chat.parse_args([
        "test",
        "--transport",
        "managed",
        "--format",
        "jsonl",
        "--approval",
        "prompt"
      ])

    assert options[:transport] == :managed
    assert options[:format] == "jsonl"
    assert options[:approval] == :prompt
  end

  test "runs an interactive session and closes without a provider TUI" do
    output =
      capture_io("hello\n/close\n", fn ->
        Mix.Tasks.JidoHarness.Chat.run(["test"])
      end)

    assert output =~ "session_id=session_"
    assert output =~ "send=turn_"
  end

  test "dispatch supports queue, status, interruption, approvals, and close" do
    assert {:ok, session_id} = Jido.Harness.open_session(:test, %{})
    assert :ok = Mix.Tasks.JidoHarness.Chat.dispatch(session_id, "/status")
    assert :ok = Mix.Tasks.JidoHarness.Chat.dispatch(session_id, "/follow-up queued")
    assert :ok = Mix.Tasks.JidoHarness.Chat.dispatch(session_id, "/interrupt")
    assert :ok = Mix.Tasks.JidoHarness.Chat.dispatch(session_id, "/deny missing")
    assert :close = Mix.Tasks.JidoHarness.Chat.dispatch(session_id, "/close")
  end
end
