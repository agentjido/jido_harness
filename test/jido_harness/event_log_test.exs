defmodule Jido.Harness.EventLogTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Buffer, Event, EventLog, Redaction}
  alias Jido.Harness.ReplayStore.{ETS, File, Memory}

  setup do
    base = Path.join(System.tmp_dir!(), "harness-event-log-#{System.unique_integer([:positive])}")
    on_exit(fn -> Elixir.File.rm_rf!(base) end)
    %{base: base}
  end

  defp event(sequence) do
    Event.new!(
      type: :output_text_delta,
      provider: :test,
      timestamp: "2026-10-16T00:00:00Z",
      sequence: sequence,
      payload: %{"text" => "fixture-secret-value", "nested" => [%{"password" => "private"}]},
      raw: %{"wire" => "original protocol bytes"}
    )
  end

  defp fill(log, sequences \\ 1..6) do
    Enum.reduce(sequences, {Buffer.new(10_000), log}, fn n, {buffer, log} ->
      EventLog.append(buffer, log, event(n), Redaction.prepare(["fixture-secret-value"]))
    end)
  end

  test "every adapter and fallback use the same prepared record policy", context do
    pages =
      for adapter <- [File, Memory, ETS] do
        options = if adapter == File, do: %{journal_dir: context.base}, else: %{}
        log = EventLog.open(:run, "same-policy", %{}, {adapter, options})
        {buffer, log} = fill(log)
        assert List.last(Buffer.events(buffer)).raw == %{"wire" => "original protocol bytes"}
        {page, log} = EventLog.replay(log, 5, 1)
        assert [%{"raw" => nil, "payload" => payload}] = page.records
        assert payload == %{"text" => "[REDACTED]", "nested" => [%{"password" => "[REDACTED]"}]}

        if adapter == File do
          contents = Elixir.File.read!(log.handle.journal.path)
          Elixir.File.rm!(log.handle.journal.path)
          {fallback, failed} = EventLog.replay(log, 5, 1)
          assert fallback.records == page.records
          assert failed.status == :degraded
          refute failed.handle.journal.failed?
          Elixir.File.write!(log.handle.journal.path, contents)
          {_buffer, recovered} = fill(failed, [7])
          {next, recovered} = EventLog.replay(recovered, 6, 1)
          assert [%{"sequence" => 7}] = next.records
          assert recovered.status == :healthy
        end

        assert :ok = EventLog.remove(log)
        page.records
      end

    assert Enum.uniq(pages) |> length() == 1
  end

  test "failed open uses a bounded sanitized fallback and reports missing ranges", context do
    Elixir.File.write!(context.base, "not a directory")
    log = EventLog.open(:run, "fallback", %{memory_bytes: 200}, {File, %{journal_dir: context.base}})
    assert log.status == :degraded
    {_, log} = fill(log)
    assert log.fallback.bytes <= 200
    {page, _} = EventLog.replay(log, 0, 100)
    assert page.gaps != []
    assert page.next_cursor == 6
    assert page.records |> Jason.encode!() |> String.contains?("fixture-secret-value") == false
  end

  test "resource kinds have separate file directories", context do
    run = EventLog.open(:run, "same-id", %{}, {File, %{journal_dir: context.base}})
    session = EventLog.open(:session, "same-id", %{}, {File, %{journal_dir: context.base}})
    refute EventLog.dir(run) == EventLog.dir(session)
    {_, run} = fill(run, [1])
    assert :ok = EventLog.close(run)
    reopened = EventLog.open(:run, "same-id", %{}, {File, %{journal_dir: context.base}})
    {page, _} = EventLog.replay(reopened, 0, 1)
    assert [%{"sequence" => 1}] = page.records
    assert :ok = EventLog.remove(run)
    assert Elixir.File.dir?(EventLog.dir(session))
  end

  test "invalid configuration fails before opening storage" do
    for config <- [{String, %{}}, {Memory, %{max_bytes: 0}}, {ETS, %{unknown: 1}}, :bad] do
      assert_raise ArgumentError, fn -> EventLog.open(:run, "bad", %{}, config) end
    end
  end

  test "write failure and raised reads use sanitized fallback" do
    for operation <- [:append, :raise] do
      log = EventLog.open(:run, "fault", %{}, {Jido.Harness.ReplayStore.FaultStore, %{operation: operation}})
      {_, log} = fill(log)
      {page, log} = EventLog.replay(log, 5, 1)
      assert log.status == :degraded
      assert [%{"raw" => nil, "payload" => %{"text" => "[REDACTED]"}}] = page.records
      assert page.next_cursor == 6
    end
  end

  test "cleanup errors are returned for retry" do
    log = EventLog.open(:run, "cleanup", %{}, {Jido.Harness.ReplayStore.FaultStore, %{operation: :delete}})
    assert {:error, :eacces} = EventLog.remove(log)
  end
end
