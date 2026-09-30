defmodule Jido.Harness.ProcessStartupRegressionTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Process, as: NativeProcess
  import Jido.Harness.TestHelpers

  setup do
    journal_dir = Path.join(System.tmp_dir!(), "harness-startup-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:jido_harness, :process_manager)
    Application.put_env(:jido_harness, :process_manager, %{journal_dir: journal_dir})

    on_exit(fn ->
      cleanup_processes()

      if previous,
        do: Application.put_env(:jido_harness, :process_manager, previous),
        else: Application.delete_env(:jido_harness, :process_manager)

      File.rm_rf!(journal_dir)
    end)

    :ok
  end

  @tag :soak
  @tag timeout: 60_000
  test "short CLI records survive concurrent startup and timeout cleanup" do
    record = Jason.encode!(%{type: "thread.started", thread_id: "startup-regression"}) <> "\n"

    for _batch <- 1..50 do
      {:ok, timed_out} =
        NativeProcess.start(%{executable: "/bin/sleep", argv: ["20"], stdin: false, runtime_timeout_ms: 100})

      short_runs =
        for _run <- 1..8 do
          {:ok, id} =
            NativeProcess.start(%{executable: "/bin/echo", argv: [String.trim_trailing(record)], stdin: false})

          id
        end

      for id <- short_runs do
        assert {:ok, info} = NativeProcess.await(id, 5_000)
        assert {:ok, events} = NativeProcess.replay(id, limit: 20)

        assert info.state == :exited and info.exit_status == 0,
               "Short process failed: #{inspect(%{info: info, events: events}, limit: :infinity)}"

        output = events |> Enum.filter(&(&1.type == :stdout)) |> Enum.map(& &1.data) |> IO.iodata_to_binary()
        assert output == record
        assert Enum.count(events, &(&1.type in [:exited, :failed, :cancelled, :timed_out])) == 1
        assert List.last(events).type == :exited
        assert :ok = NativeProcess.prune(id)
      end

      assert {:ok, info} = NativeProcess.await(timed_out, 5_000)
      assert {:ok, events} = NativeProcess.replay(timed_out, limit: 20)

      assert info.state == :timed_out,
             "Timeout process failed: #{inspect(%{info: info, events: events}, limit: :infinity)}"

      assert :ok = NativeProcess.prune(timed_out)
    end
  end
end
