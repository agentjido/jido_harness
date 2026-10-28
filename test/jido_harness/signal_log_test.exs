defmodule Jido.Harness.SignalLogTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Buffer, Redaction, SignalFactory, SignalLog}
  alias Jido.Harness.ReplayStore.{ETS, File, Memory}
  alias Jido.Harness.ReplayStore.{FaultStore, Page}

  setup do
    base = Path.join(System.tmp_dir!(), "harness-signal-log-#{System.unique_integer([:positive])}")
    on_exit(fn -> Elixir.File.rm_rf!(base) end)
    %{base: base}
  end

  defp signal(sequence) do
    SignalFactory.fact(:output_text_delta, %{
      sequence: sequence,
      payload: %{"text" => "fixture-secret-value", "nested" => [%{"password" => "private"}]}
    })
  end

  defp fill(log, sequences \\ 1..6) do
    Enum.reduce(sequences, {Buffer.new(10_000), log}, fn n, {buffer, log} ->
      SignalLog.append(buffer, log, signal(n), Redaction.prepare(["fixture-secret-value"]))
    end)
  end

  test "every adapter and fallback use the same prepared record policy", context do
    pages =
      for adapter <- [File, Memory, ETS] do
        options = if adapter == File, do: %{journal_dir: context.base}, else: %{}
        log = SignalLog.open(:run, "same-policy", %{}, {adapter, options})
        {buffer, log} = fill(log)
        assert SignalFactory.payload(List.last(Buffer.signals(buffer)))["text"] == "fixture-secret-value"
        {page, log} = SignalLog.replay(log, 5, 1)
        assert [%{"signal" => %{"data" => %{"payload" => payload}}}] = page.records
        assert payload == %{"text" => "[REDACTED]", "nested" => [%{"password" => "[REDACTED]"}]}

        if adapter == File do
          contents = Elixir.File.read!(log.handle.journal.path)
          Elixir.File.rm!(log.handle.journal.path)
          {fallback, failed} = SignalLog.replay(log, 5, 1)
          assert fallback.records == page.records
          assert failed.status == :degraded
          refute failed.handle.journal.failed?
          Elixir.File.write!(log.handle.journal.path, contents)
          {_buffer, recovered} = fill(failed, [7])
          {next, recovered} = SignalLog.replay(recovered, 6, 1)
          assert [%{"sequence" => 7}] = next.records
          assert recovered.status == :healthy
        end

        assert :ok = SignalLog.remove(log)
        Enum.map(page.records, fn record -> update_in(record, ["signal"], &Map.delete(&1, "id")) end)
      end

    assert Enum.uniq(pages) |> length() == 1
  end

  test "failed open uses a bounded sanitized fallback and reports missing ranges", context do
    Elixir.File.write!(context.base, "not a directory")
    log = SignalLog.open(:run, "fallback", %{memory_bytes: 200}, {File, %{journal_dir: context.base}})
    assert log.status == :degraded
    {_, log} = fill(log)
    assert log.fallback.bytes <= 200
    {page, _} = SignalLog.replay(log, 0, 100)
    assert page.gaps != []
    assert page.next_cursor == 6
    assert page.records |> Jason.encode!() |> String.contains?("fixture-secret-value") == false
  end

  test "resource kinds have separate file directories", context do
    run = SignalLog.open(:run, "same-id", %{}, {File, %{journal_dir: context.base}})
    session = SignalLog.open(:session, "same-id", %{}, {File, %{journal_dir: context.base}})
    refute SignalLog.dir(run) == SignalLog.dir(session)
    {_, run} = fill(run, [1])
    assert :ok = SignalLog.close(run)
    reopened = SignalLog.open(:run, "same-id", %{}, {File, %{journal_dir: context.base}})
    {page, _} = SignalLog.replay(reopened, 0, 1)
    assert [%{"sequence" => 1}] = page.records
    assert :ok = SignalLog.remove(run)
    assert Elixir.File.dir?(SignalLog.dir(session))
  end

  test "invalid configuration fails before opening storage" do
    for config <- [{String, %{}}, {Memory, %{max_bytes: 0}}, {ETS, %{unknown: 1}}, :bad] do
      assert_raise ArgumentError, fn -> SignalLog.open(:run, "bad", %{}, config) end
    end
  end

  test "write failure and raised reads use sanitized fallback" do
    for operation <- [:append, :raise] do
      log = SignalLog.open(:run, "fault", %{}, {Jido.Harness.ReplayStore.FaultStore, %{operation: operation}})
      {_, log} = fill(log)
      {page, log} = SignalLog.replay(log, 5, 1)
      assert log.status == :degraded
      assert [%{"signal" => %{"data" => %{"payload" => %{"text" => "[REDACTED]"}}}}] = page.records
      assert page.next_cursor == 6
    end
  end

  test "cleanup errors are returned for retry" do
    log = SignalLog.open(:run, "cleanup", %{}, {Jido.Harness.ReplayStore.FaultStore, %{operation: :delete}})
    assert {:error, :eacces} = SignalLog.remove(log)
  end

  test "a read failure after reopen reports the known sequence range", context do
    config = {File, %{journal_dir: context.base}}
    log = SignalLog.open(:run, "reopened-failure", %{}, config)
    {_, log} = fill(log)
    assert :ok = SignalLog.close(log)
    reopened = SignalLog.open(:run, "reopened-failure", %{}, config)
    Elixir.File.rm!(reopened.handle.journal.segments[0].path)
    {page, failed} = SignalLog.replay(reopened, 0, 100)
    assert failed.status == :degraded
    assert page.records == []
    assert page.latest_sequence == 6
    assert page.next_cursor == 6
    assert page.gaps == [%{from: 1, to: 6, reason: :unavailable}]
    assert SignalLog.info(failed).latest_sequence == 6
  end

  test "invalid callback results use the fallback and do not stop the caller" do
    for operation <- [:invalid_open, :invalid_append, :invalid_read, :invalid_info] do
      log = SignalLog.open(:run, "invalid", %{}, {FaultStore, %{operation: operation}})
      {_, log} = fill(log)
      {page, log} = SignalLog.replay(log, 5, 1)
      assert log.status == :degraded
      assert [%{"sequence" => 6}] = page.records
      assert SignalLog.info(log).latest_sequence == 6
    end

    for operation <- [:invalid_close, :invalid_delete] do
      log = SignalLog.open(:run, "invalid", %{}, {FaultStore, %{operation: operation}})
      result = if operation == :invalid_close, do: SignalLog.close(log), else: SignalLog.remove(log)
      assert result == {:error, :invalid_callback_result}
    end
  end

  test "invalid pages cannot regress, stall, overlap gaps, or exceed limits" do
    record = Jido.Harness.ReplayStore.Record.prepare(signal(6), [])

    for page <- [
          :bad_page,
          %Page{next_cursor: 4, latest_sequence: 6},
          %Page{next_cursor: 5, latest_sequence: 6},
          %Page{records: [record, record], next_cursor: 6, latest_sequence: 6},
          %Page{records: [record], gaps: [%{from: 6, to: 6, reason: :unavailable}], next_cursor: 6, latest_sequence: 6},
          %Page{records: [record], next_cursor: 6, latest_sequence: 6, bytes: 100_001}
        ] do
      log = SignalLog.open(:run, "invalid-page", %{}, {FaultStore, %{page: page}})
      {_, log} = fill(log)
      {page, failed} = SignalLog.replay(log, 5, 1, 100_000)
      assert failed.status == :degraded
      assert [%{"sequence" => 6}] = page.records
      assert page.next_cursor == 6
    end
  end

  test "nil is a valid opaque store handle" do
    log = SignalLog.open(:run, "opaque", %{}, {FaultStore, %{operation: :nil_handle}})
    {_, log} = fill(log, [1])
    assert_receive :opaque_append
    assert :ok = SignalLog.remove(log)
    assert_receive :opaque_delete
  end

  test "term conversion cannot expose secrets that redaction could not traverse" do
    record =
      Jido.Harness.ReplayStore.Record.prepare(
        SignalFactory.fact(:output_text_delta, %{
          payload: %{tuple: {:value, "fixture-secret-value"}, atom: :"fixture-secret-value"}
        }),
        ["fixture-secret-value"]
      )

    refute Jason.encode!(record) =~ "fixture-secret-value"
    payload = get_in(record, ["signal", "data", "payload"])
    assert payload["tuple"] =~ "[REDACTED]"
    assert payload["atom"] == "[REDACTED]"
  end

  test "a secret equal to a provider name cannot change the Signal envelope" do
    record = Jido.Harness.ReplayStore.Record.prepare(signal(1), ["test"])
    assert record["signal"]["type"] == "jido.harness.output.text.delta"
    assert record["signal"]["source"] == "urn:jido:harness:run:fixture"
  end
end
