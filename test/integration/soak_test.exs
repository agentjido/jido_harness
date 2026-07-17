defmodule Jido.Harness.Integration.SoakTest do
  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: 7_200_000

  test "manages the deterministic fixture for 65 minutes" do
    fixture = Jido.Harness.TestHelpers.fixture_path("long_running_cli.exs")

    assert {:ok, process_id} =
             Jido.Harness.start_process(%{
               executable: System.find_executable("elixir"),
               argv: [fixture, "3900000", "30000"],
               stdin: false,
               runtime_timeout_ms: 4_200_000,
               idle_timeout_ms: 60_000
             })

    assert {:ok, %{state: :exited, exit_status: 0}} =
             Jido.Harness.await_process(process_id, 4_300_000)
  end
end
