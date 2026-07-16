defmodule Mix.Tasks.JidoHarness.QueryTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  alias Mix.Tasks.JidoHarness.Query

  setup context do
    shell = Mix.shell()
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-query-test-#{System.unique_integer([:positive])}")

    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("jido_harness.query")

    on_exit(fn ->
      Mix.shell(shell)
      Mix.Task.reenable("jido_harness.query")
    end)

    :ok
  end

  test "sends a prompt through the selected harness and prints its run identity and response" do
    assert :ok = Mix.Task.run("jido_harness.query", ["test", "hello from mix", "--timeout", "5"])

    output = shell_output()
    assert output =~ "[test] run_id=run_"
    assert output =~ "status=completed"
    assert output =~ "fixture-ok"
  end

  test "supports comma-separated and all provider selection without creating atoms" do
    specs = [Jido.Harness.TestAdapter.spec(), Jido.Harness.Adapters.Codex.spec()]

    assert Query.select_providers("codex,test,codex", specs) == [:codex, :test]
    assert Query.select_providers("all", specs) == [:test, :codex]

    assert_raise Mix.Error, ~r/unknown providers: invented/, fn ->
      Query.select_providers("invented", specs)
    end
  end

  test "validates usage and positive timeout options" do
    assert_raise Mix.Error, ~r/usage:/, fn -> Query.parse_args(["test"]) end

    assert_raise Mix.Error, ~r/--timeout must be a positive integer/, fn ->
      Query.parse_args(["test", "hello", "--timeout", "0"])
    end
  end

  test "fails when a provider run fails or output does not match the expectation" do
    assert_raise Mix.Error, ~r/query failed: test/, fn ->
      Mix.Task.run("jido_harness.query", ["test", "fail", "--timeout", "5"])
    end

    Mix.Task.reenable("jido_harness.query")

    assert_raise Mix.Error, ~r/query failed: test/, fn ->
      Mix.Task.run("jido_harness.query", ["test", "hello", "--expect", "different", "--timeout", "5"])
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
