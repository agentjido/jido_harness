defmodule Jido.Harness.JournalLoadTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{Journal, ReplayProbe}

  @moduletag :load
  @moduletag timeout: 180_000

  setup do
    base = Path.join(System.tmp_dir!(), "jido-harness-replay-load-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      base: base,
      records: positive_env("HARNESS_REPLAY_RECORDS", 16_000),
      readers: positive_env("HARNESS_REPLAY_READERS", 4),
      payload_bytes: positive_env("HARNESS_REPLAY_PAYLOAD_BYTES", 1_024)
    }
  end

  test "single-record pages scale with consumed events, not journal history", context do
    sizes = [max(1, div(context.records, 16)), max(1, div(context.records, 4)), context.records] |> Enum.uniq()

    for count <- sizes do
      journal = build_journal(context, count)

      {:ok, stats} =
        ReplayProbe.measure(fn ->
          for cursor <- 0..(count - 1) do
            assert {[%{"sequence" => sequence}], _journal} = Journal.replay(journal, cursor, 1)
            assert sequence == cursor + 1
          end

          :ok
        end)

      assert stats.calls == count
      assert stats.returned_records == count
      assert stats.max_decoded_records <= 64
      assert stats.decoded_records <= 64 * count
      report("single_record_pages", journal, stats, %{records: count})

      {:ok, stats} =
        ReplayProbe.measure(fn ->
          for _poll <- 1..1_000 do
            assert {[], _journal} = Journal.replay(journal, count, 100)
          end

          :ok
        end)

      assert stats.calls == 1_000
      assert stats.decoded_records == 0
      assert stats.read_bytes == 0
      assert stats.segments_opened == 0
      report("caught_up_polls", journal, stats, %{records: count})
    end
  end

  test "concurrent readers keep independent cursors across rotated segments", context do
    journal = build_journal(context, context.records, %{segment_bytes: 262_144})
    started = System.monotonic_time(:microsecond)

    results =
      1..context.readers
      |> Task.async_stream(
        fn reader ->
          page_size = Enum.at([1, 17, 100, 257], rem(reader - 1, 4))
          {last, stats} = ReplayProbe.measure(fn -> consume(journal, 0, page_size) end)
          assert last == context.records
          assert stats.calls > 0
          assert stats.returned_records == context.records
          assert stats.decoded_records <= context.records + 64 * stats.calls
          report("concurrent_reader", journal, stats, %{reader: reader, page_size: page_size})
          stats
        end,
        max_concurrency: context.readers,
        ordered: false,
        timeout: 180_000
      )
      |> Enum.map(fn {:ok, stats} -> stats end)

    assert length(results) == context.readers

    report("concurrent_total", journal, %{elapsed_us: System.monotonic_time(:microsecond) - started}, %{
      readers: context.readers,
      records: context.records
    })
  end

  test "a growing journal keeps write and tail-poll work bounded", context do
    {:ok, journal} = Journal.open("growing", %{journal_dir: context.base})
    payload = String.duplicate("x", context.payload_bytes)

    {journal, stats} =
      ReplayProbe.measure(fn ->
        Enum.reduce(1..context.records, journal, fn sequence, journal ->
          assert {:ok, journal} = Journal.append(journal, %{sequence: sequence, payload: payload})
          assert {[%{"sequence" => ^sequence}], journal} = Journal.replay(journal, sequence - 1, 1)
          assert {[], journal} = Journal.replay(journal, sequence, 100)
          journal
        end)
      end)

    assert stats.calls == 2 * context.records
    assert stats.returned_records == context.records
    assert stats.max_decoded_records <= 64
    assert stats.decoded_records <= 64 * context.records
    report("growing_tail", journal, stats, %{records: context.records})
  end

  defp consume(journal, cursor, _page_size) when cursor >= journal.latest_sequence, do: cursor

  defp consume(journal, cursor, page_size) do
    {records, journal} = Journal.replay(journal, cursor, page_size)
    sequences = Enum.map(records, & &1["sequence"])
    last = min(journal.latest_sequence, cursor + page_size)
    assert sequences == Enum.to_list((cursor + 1)..last)
    consume(journal, last, page_size)
  end

  defp build_journal(context, count, options \\ %{}) do
    disk_limit = max(512 * 1_024 * 1_024, (context.payload_bytes + 128) * count)
    options = Map.merge(%{journal_dir: context.base, disk_limit_bytes: disk_limit}, options)
    {:ok, journal} = Journal.open("records-#{count}", options)
    payload = String.duplicate("x", context.payload_bytes)

    Enum.reduce(1..count, journal, fn sequence, journal ->
      {:ok, journal} = Journal.append(journal, %{sequence: sequence, payload: payload})
      journal
    end)
  end

  defp report(scenario, journal, stats, extra) do
    {duration, stats} = Map.pop(stats, :max_duration, 0)

    stats =
      stats
      |> Map.put(:max_replay_us, System.convert_time_unit(duration, :native, :microsecond))
      |> Map.merge(extra)
      |> Map.merge(%{
        scenario: scenario,
        journal_bytes: journal.total_bytes,
        index_bytes: :erlang.external_size(journal.segments),
        segments: map_size(journal.segments),
        elixir: System.version(),
        otp: System.otp_release()
      })

    IO.puts("journal_load " <> Jason.encode!(stats))
  end

  defp positive_env(name, default) do
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {value, ""} when value > 0 -> value
      _other -> raise ArgumentError, "#{name} must be a positive integer"
    end
  end
end
