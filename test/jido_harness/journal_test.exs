defmodule Jido.Harness.JournalTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Journal
  alias Jido.Harness.ReplayProbe

  setup do
    base = Path.join(System.tmp_dir!(), "jido-harness-replay-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "tail reads have bounded decode work and caught-up polls do no file work", %{base: base} do
    journal = build_journal(base, 4_096)

    {{records, journal}, stats} = ReplayProbe.measure(fn -> Journal.replay(journal, 4_095, 1) end)
    assert [%{"sequence" => 4_096}] = records
    assert stats.calls == 1
    assert stats.decoded_records <= 64
    assert stats.segments_opened == 1

    {{[], _journal}, stats} = ReplayProbe.measure(fn -> Journal.replay(journal, 4_096, 100) end)
    assert stats.calls == 1
    assert stats.decoded_records == 0
    assert stats.read_bytes == 0
    assert stats.segments_opened == 0
  end

  test "independent cursors can seek backward and cross segment boundaries", %{base: base} do
    journal = build_journal(base, 500, %{segment_bytes: 4_096})

    for {cursor, limit} <- [{401, 50}, {0, 1}, {62, 100}, {499, 100}, {150, 17}] do
      {records, updated} = Journal.replay(journal, cursor, limit)
      assert Enum.map(records, & &1["sequence"]) == Enum.to_list((cursor + 1)..min(500, cursor + limit))
      refute updated.read_failed?
    end
  end

  test "large records use byte checkpoints to bound skipped data", %{base: base} do
    journal = build_journal(base, 100, %{segment_bytes: 2_000_000}, 32_768)
    {{records, _journal}, stats} = ReplayProbe.measure(fn -> Journal.replay(journal, 98, 1) end)
    assert [%{"sequence" => 99}] = records
    assert stats.decoded_records <= 3
    assert stats.read_bytes < 100_000
  end

  test "reopening builds the index once and preserves append and retention state", %{base: base} do
    before = build_journal(base, 300, %{segment_bytes: 4_096, disk_limit_bytes: 16_384})
    assert {:ok, journal} = Journal.open("replay", %{journal_dir: base, segment_bytes: 4_096, disk_limit_bytes: 16_384})
    assert journal.total_bytes == before.total_bytes
    assert journal.available_from == before.available_from
    assert journal.latest_sequence == 300
    assert {:ok, journal} = Journal.append(journal, %{sequence: 301, payload: "new"})

    {{records, _journal}, stats} = ReplayProbe.measure(fn -> Journal.replay(journal, 299, 10) end)
    assert Enum.map(records, & &1["sequence"]) == [300, 301]
    assert stats.decoded_records <= 65
  end

  test "tail replay skips unavailable segments before the cursor", %{base: base} do
    journal = build_journal(base, 100, %{segment_bytes: 500})
    {_number, oldest} = Enum.min_by(journal.segments, &elem(&1, 0))
    File.rm!(oldest.path)
    {records, updated} = Journal.replay(journal, 99, 1)
    assert [%{"sequence" => 100}] = records
    refute updated.read_failed?
    refute updated.failed?
  end

  test "read errors permit writes and a later read can recover", %{base: base} do
    journal = build_journal(base, 100, %{segment_bytes: 4_096})
    {_number, oldest} = Enum.min_by(journal.segments, &elem(&1, 0))
    original = File.read!(oldest.path)
    File.rm!(oldest.path)

    assert {[], journal} = Journal.replay(journal, 0, 1)
    assert journal.read_failed?
    refute journal.failed?

    assert {:ok, journal} = Journal.append(journal, %{sequence: 101, payload: "after read error"})
    File.write!(oldest.path, original)
    assert {[%{"sequence" => 1}], journal} = Journal.replay(journal, 0, 1)
    assert {[%{"sequence" => 101}], journal} = Journal.replay(journal, 100, 1)
    refute journal.read_failed?
    refute journal.failed?
  end

  test "invalid sequence values do not damage the index or stop later writes", %{base: base} do
    journal = build_journal(base, 2)

    for sequence <- [nil, "3", 0, 1, 2] do
      assert {:error, :invalid_sequence, ^journal} = Journal.append(journal, %{sequence: sequence})
    end

    assert {:ok, journal} = Journal.append(journal, %{"sequence" => 3})
    assert {[%{"sequence" => 3}], _journal} = Journal.replay(journal, 2, 10)
  end

  test "rotates bounded disk segments and reports a cursor replay gap" do
    base = Path.join(System.tmp_dir!(), "jido-harness-journal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, journal} =
             Journal.open("rotation", %{
               journal_dir: base,
               segment_bytes: 180,
               disk_limit_bytes: 420
             })

    journal =
      Enum.reduce(1..20, journal, fn sequence, journal ->
        assert {:ok, journal} =
                 Journal.append(journal, %{
                   sequence: sequence,
                   payload: String.duplicate("x", 80)
                 })

        journal
      end)

    assert journal.total_bytes <= journal.disk_limit_bytes
    assert journal.available_from > 1
    {records, _journal} = Journal.replay(journal, 0, 100)
    assert [%{"sequence" => first} | _] = records
    assert first == journal.available_from
    assert map_size(journal.segments) == length(Path.wildcard(Path.join(journal.dir, "*.jsonl")))
    assert Enum.all?(journal.segments, fn {_number, segment} -> segment.first >= journal.available_from end)
  end

  test "returns an error when the secure journal directory cannot be created" do
    file = Path.join(System.tmp_dir!(), "jido-harness-journal-file-#{System.unique_integer([:positive])}")
    File.write!(file, "not a directory")
    on_exit(fn -> File.rm(file) end)

    assert {:error, _reason} = Journal.open("failure", %{journal_dir: file})
  end

  defp build_journal(base, count, options \\ %{}, payload_bytes \\ 128) do
    {:ok, journal} = Journal.open("replay", Map.put(options, :journal_dir, base))
    payload = String.duplicate("x", payload_bytes)

    Enum.reduce(1..count, journal, fn sequence, journal ->
      {:ok, journal} = Journal.append(journal, %{sequence: sequence, payload: payload})
      journal
    end)
  end
end
