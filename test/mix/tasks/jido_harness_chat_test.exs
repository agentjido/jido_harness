defmodule Mix.Tasks.JidoHarness.ChatTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  alias Mix.Tasks.JidoHarness.Chat

  setup context do
    shell = Mix.shell()
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-chat-test-#{System.unique_integer([:positive])}")

    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("jido_harness.chat")

    on_exit(fn ->
      Mix.shell(shell)
      Mix.Task.reenable("jido_harness.chat")
    end)

    :ok
  end

  test "uses a minimal default prompt and validates timeout" do
    {options, "test", "Reply with exactly: ready"} = Chat.parse_args(["test"])
    assert options[:timeout] == 300

    assert_raise Mix.Error, ~r/--timeout must be a positive integer/, fn ->
      Chat.parse_args(["test", "--timeout", "0"])
    end
  end

  test "selects exactly one registered provider without creating atoms" do
    specs = [Jido.Harness.TestAdapter.spec(), Jido.Harness.Adapters.Codex.spec()]

    assert Chat.select_provider("codex", specs) == :codex

    assert_raise Mix.Error, ~r/unknown provider: all/, fn ->
      Chat.select_provider("all", specs)
    end
  end

  test "runs one live-style query and prints a compact result" do
    assert :ok = Mix.Task.run("jido_harness.chat", ["test", "hello", "--timeout", "5"])

    output = shell_output()
    assert output =~ "[test] ok run_id=run_"
    assert output =~ "fixture-ok"
  end

  test "fails after reporting an unsuccessful provider" do
    assert_raise Mix.Error, ~r/chat failed: test/, fn ->
      Mix.Task.run("jido_harness.chat", ["test", "fail", "--timeout", "5"])
    end
  end

  defp shell_output do
    receive_shell([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp receive_shell(messages) do
    receive do
      {:mix_shell, _level, [message]} when is_binary(message) -> receive_shell([message | messages])
      _other -> receive_shell(messages)
    after
      0 -> messages
    end
  end
end
