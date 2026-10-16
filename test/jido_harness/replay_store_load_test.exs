defmodule Jido.Harness.ReplayStoreLoadTest do
  use ExUnit.Case, async: false
  alias Jido.Harness.ReplayStore.{ETS, Memory}

  @moduletag :load
  @moduletag timeout: 120_000

  test "memory cursor work stays bounded as retained history grows" do
    for adapter <- [Memory, ETS] do
      stats =
        for count <- [2_000, 16_000] do
          {:ok, handle} =
            adapter.open(%{kind: :run, id: "load", format_version: 1}, %{max_events: 20_000, max_bytes: 16_000_000})

          handle =
            Enum.reduce(1..count, handle, fn n, handle ->
              {:ok, handle} = adapter.append(handle, %{"sequence" => n, "payload" => String.duplicate("x", 128)})
              handle
            end)

          {_, before} = Process.info(self(), :reductions)

          for n <- 1..500 do
            cursor = count - rem(n, 100) - 1

            assert {:ok, %{records: [%{"sequence" => sequence}]}, _} =
                     adapter.read(handle, cursor, %{max_events: 1, max_bytes: 1_000})

            assert sequence == cursor + 1

            assert {:ok, %{records: [], gaps: [], next_cursor: ^count}, _} =
                     adapter.read(handle, count, %{max_events: 1, max_bytes: 1_000})
          end

          {_, after_count} = Process.info(self(), :reductions)
          reductions = after_count - before
          assert reductions < 1_000_000
          assert :ok = adapter.delete(handle)

          IO.puts(
            "replay_store_load " <>
              Jason.encode!(%{adapter: inspect(adapter), records: count, reads: 1_000, reductions: reductions})
          )

          reductions
        end

      [small, large] = stats
      assert large < small * 2
    end
  end
end
