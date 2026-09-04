Code.require_file("../../examples/policy_job.exs", __DIR__)

defmodule Jido.Harness.PolicyJobExampleTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Examples.PolicyJob
  import Jido.Harness.TestHelpers

  setup context do
    journal_dir = Path.join(System.tmp_dir!(), "harness-policy-#{System.unique_integer([:positive])}")
    configure_test_provider(Map.put(context, :journal_dir, journal_dir))
    :ok
  end

  test "a bounded job uses host policy and closes its session and process" do
    caller = self()

    policy = fn event ->
      send(caller, {:policy_request, event})
      :approve
    end

    assert {:ok, %{status: :completed, text: "approved"}} = PolicyJob.run(:test, "approval", policy)
    assert_receive {:policy_request, %{type: :approval_requested, request_id: request_id}}
    assert String.starts_with?(request_id, "request_")
    assert_closed()
  end

  test "policy errors, invalid answers, and timeouts deny access" do
    for policy <- [
          fn _ -> raise "policy failed" end,
          fn _ -> :invalid end,
          fn _ ->
            Process.sleep(1_000)
            :approve
          end
        ] do
      assert {:ok, %{status: :completed, text: "denied"}} =
               PolicyJob.run(:test, "approval", policy, policy_timeout_ms: 50)
    end

    assert_closed()
  end

  test "a job deadline closes its session even when the provider waits" do
    result = PolicyJob.run(:test, "wait", fn _ -> :deny end, timeout_ms: 50)
    assert match?({:error, :timeout}, result) or match?({:ok, %{status: :failed}}, result)
    assert_closed()
  end

  defp assert_closed do
    assert Enum.all?(Jido.Harness.Session.list(), &Jido.Harness.SessionInfo.terminal?/1)

    Enum.each(Jido.Harness.Process.list(), fn info ->
      assert {:ok, final} = Jido.Harness.Process.await(info.process_id, 2_000)
      assert Jido.Harness.ProcessInfo.terminal?(final)
    end)
  end
end
