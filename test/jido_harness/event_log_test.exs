defmodule Jido.Harness.EventLogTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Buffer, EventLog, Journal}

  setup do
    base = Path.join(System.tmp_dir!(), "jido-harness-event-log-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, journal} = Journal.open("fallback", %{journal_dir: base})

    {buffer, journal} =
      Enum.reduce(1..6, {Buffer.new(1_000_000), journal}, fn sequence, {buffer, journal} ->
        record = %{sequence: sequence, raw: nil, payload: %{"text" => "event #{sequence}"}}
        {:ok, journal} = Journal.append(journal, record)
        {Buffer.append(buffer, record), journal}
      end)

    %{buffer: buffer, journal: journal}
  end

  test "a failed disk read returns the memory tail on the same call and retries later", context do
    %{buffer: buffer, journal: journal} = context
    contents = File.read!(journal.path)
    File.rm!(journal.path)

    assert {[event], journal, 6} = EventLog.replay(buffer, journal, 5, 1)
    assert event.sequence == 6
    assert journal.read_failed?
    refute journal.failed?

    File.write!(journal.path, contents)
    assert {:ok, journal} = Journal.append(journal, %{sequence: 7, raw: nil})
    assert {[%{"sequence" => 7}], journal, 1} = EventLog.replay(buffer, journal, 6, 1)
    refute journal.read_failed?
  end

  test "memory fallback reports a gap when earlier events are no longer retained", context do
    %{journal: journal} = context
    buffer = Buffer.append(Buffer.new(1_000), %{sequence: 6})
    File.rm!(journal.path)
    assert {[%{sequence: 6}], journal, 6} = EventLog.replay(buffer, journal, 0, 100)
    refute journal.failed?
  end

  test "healthy disk replay retains the redacted persistence boundary", context do
    %{journal: journal} = context
    buffer = Buffer.append(Buffer.new(1_000), %{sequence: 6, raw: "memory only"})
    assert {[%{"raw" => nil, "sequence" => 6}], _journal, 1} = EventLog.replay(buffer, journal, 5, 1)
  end
end
