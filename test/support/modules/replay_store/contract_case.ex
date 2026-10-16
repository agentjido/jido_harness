defmodule Jido.Harness.ReplayStore.ContractCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using options do
    quote do
      @adapter unquote(Keyword.fetch!(options, :adapter))
      alias Jido.Harness.ReplayStore.Record

      setup do
        base = Path.join(System.tmp_dir!(), "replay-contract-#{System.unique_integer([:positive])}")
        on_exit(fn -> File.rm_rf!(base) end)
        %{base: base, resource: %{kind: :run, id: "contract", format_version: 1}}
      end

      defp open(context, options \\ %{}) do
        options =
          if @adapter == Jido.Harness.ReplayStore.File do
            options
            |> Map.new(fn
              {:max_bytes, bytes} -> {:disk_limit_bytes, bytes}
              pair -> pair
            end)
            |> Map.merge(%{journal_dir: context.base, segment_bytes: 1})
          else
            options
          end

        assert {:ok, handle} = @adapter.open(context.resource, options)
        handle
      end

      defp append(handle, sequences) do
        Enum.reduce(sequences, handle, fn n, handle ->
          assert {:ok, handle} = @adapter.append(handle, record(n))
          handle
        end)
      end

      defp record(n), do: %{"sequence" => n, "format_version" => 1, "payload" => "event"}
      defp limits(count \\ 100, bytes \\ 1_048_576), do: %{max_events: count, max_bytes: bytes}

      test "unsupported resource formats are rejected", context do
        assert {:error, :invalid_resource} = @adapter.open(%{context.resource | format_version: 2}, %{})
        assert {:error, _reason} = @adapter.validate_options(%{unknown: 1})
      end

      test "empty reads preserve forward cursor progress", context do
        handle = open(context)
        assert {:ok, page, _} = @adapter.read(handle, 0, limits())
        assert page.records == []
        assert page.gaps == []
        assert page.oldest_sequence == nil
        assert page.latest_sequence == 0
        assert page.next_cursor == 0
        assert {:ok, %{next_cursor: 50, records: [], gaps: []}, _} = @adapter.read(handle, 50, limits())
      end

      test "ordered pages report internal gaps only as far as the next cursor", context do
        handle = context |> open() |> append([1, 4, 6])
        assert {:ok, page, handle} = @adapter.read(handle, 0, limits(2))
        assert page.records == [record(1), record(4)]
        assert page.gaps == [%{from: 2, to: 3, reason: :unavailable}]
        assert page.next_cursor == 4
        assert page.oldest_sequence == 1
        assert page.latest_sequence == 6
        assert {:ok, next, handle} = @adapter.read(handle, page.next_cursor, limits())
        assert next.records == [record(6)]
        assert next.gaps == [%{from: 5, to: 5, reason: :unavailable}]
        assert next.next_cursor == 6
        assert {:ok, %{records: [], gaps: [], next_cursor: 6}, _} = @adapter.read(handle, 6, limits())
      end

      test "the byte limit ends a page without discarding the next fitting record", context do
        handle = context |> open() |> append(1..3)
        bytes = Record.bytes(record(1))
        assert {:ok, page, handle} = @adapter.read(handle, 0, limits(10, bytes))
        assert page.records == [record(1)]
        assert page.bytes == bytes
        assert page.next_cursor == 1
        assert page.gaps == []
        assert {:ok, next, _} = @adapter.read(handle, 1, limits(10, bytes))
        assert next.records == [record(2)]
      end

      test "records too large for a page report gaps and do not stall its cursor", context do
        handle = open(context)
        assert {:ok, handle} = @adapter.append(handle, record(1))
        large = Map.put(record(2), "payload", String.duplicate("x", 1_000))
        assert {:ok, handle} = @adapter.append(handle, large)
        assert {:ok, handle} = @adapter.append(handle, record(3))
        bytes = Record.bytes(record(1)) * 2
        assert {:ok, page, handle} = @adapter.read(handle, 0, limits(3, bytes))
        assert page.records == [record(1), record(3)]
        assert page.gaps == [%{from: 2, to: 2, reason: :page_limit}]
        assert page.next_cursor == 3
        assert page.bytes <= bytes
        assert {:ok, %{records: [^large]}, _} = @adapter.read(handle, 1, limits(1))
      end

      test "count bounds include skipped records and bound gap metadata", context do
        handle = context |> open() |> append(1..100)
        assert {:ok, page, _} = @adapter.read(handle, 0, limits(3, 1))
        assert page.records == []
        assert page.gaps == [%{from: 1, to: 3, reason: :page_limit}]
        assert page.next_cursor == 3
      end

      test "oversized appends preserve sequence progress without exceeding retention", context do
        handle = open(context, %{max_bytes: 100})
        large = Map.put(record(5), "payload", String.duplicate("x", 1_000))
        assert {:error, :record_too_large, handle} = @adapter.append(handle, large)
        assert @adapter.info(handle).retained_bytes <= 100
        assert @adapter.info(handle).retained_events == 0
        assert {:ok, page, _} = @adapter.read(handle, 0, limits())
        assert page.records == []
        assert page.gaps == [%{from: 1, to: 5, reason: :unavailable}]
        assert page.next_cursor == 5
        assert page.latest_sequence == 5
        assert page.oldest_sequence == nil
      end

      test "a rejected middle record does not prevent later writes", context do
        handle = open(context, %{max_bytes: 128})
        assert {:ok, handle} = @adapter.append(handle, record(1))
        large = Map.put(record(2), "payload", String.duplicate("x", 1_000))
        assert {:error, :record_too_large, handle} = @adapter.append(handle, large)
        assert {:ok, handle} = @adapter.append(handle, record(3))
        assert {:ok, page, _} = @adapter.read(handle, 0, limits())
        assert page.records == [record(1), record(3)]
        assert page.gaps == [%{from: 2, to: 2, reason: :unavailable}]
        assert page.next_cursor == 3
      end

      test "event retention is bounded and reports the removed prefix", context do
        handle = context |> open(%{max_events: 2}) |> append(1..4)
        assert @adapter.info(handle).retained_events <= 2
        assert {:ok, page, _} = @adapter.read(handle, 0, limits())
        assert page.records == [record(3), record(4)]
        assert page.gaps == [%{from: 1, to: 2, reason: :unavailable}]
        assert page.oldest_sequence == 3
      end

      test "byte retention remains bounded under sustained append", context do
        budget = 2 * (Record.bytes(record(1)) + 1)
        handle = context |> open(%{max_bytes: budget}) |> append(1..9)
        assert @adapter.info(handle).retained_bytes <= budget
        assert {:ok, page, _} = @adapter.read(handle, 0, limits())
        assert page.next_cursor == 9
        assert page.gaps != []
        assert List.last(page.records) == record(9)
      end

      test "retained duplicates are idempotent and different data conflicts", context do
        handle = context |> open() |> append(1..2)
        info = @adapter.info(handle)
        assert {:ok, handle} = @adapter.append(handle, record(1))
        assert @adapter.info(handle) == info
        assert {:error, :sequence_conflict, handle} = @adapter.append(handle, Map.put(record(1), "payload", "other"))
        assert {:ok, %{records: records}, _} = @adapter.read(handle, 0, limits())
        assert records == [record(1), record(2)]
      end

      test "expired sequences cannot be inserted again", context do
        handle = context |> open(%{max_events: 1}) |> append(1..2)
        assert {:error, :expired_sequence, _} = @adapter.append(handle, record(1))
      end

      test "close does not delete records and delete is idempotent", context do
        handle = context |> open() |> append([1])
        assert :ok = @adapter.close(handle)
        assert {:ok, %{records: records}, _} = @adapter.read(handle, 0, limits())
        assert records == [record(1)]
        assert :ok = @adapter.delete(handle)
        assert :ok = @adapter.delete(handle)
      end

      test "invalid cursors and limits are rejected", context do
        handle = open(context)
        assert {:error, :invalid_replay_limits, _} = @adapter.read(handle, -1, limits())
        assert {:error, :invalid_replay_limits, _} = @adapter.read(handle, 0, limits(0))
        assert {:error, :invalid_replay_limits, _} = @adapter.read(handle, 0, limits(1, 0))
        assert {:error, :invalid_sequence, _} = @adapter.append(handle, %{"sequence" => 0})
      end
    end
  end
end
