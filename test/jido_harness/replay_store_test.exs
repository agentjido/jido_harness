defmodule Jido.Harness.FileReplayStoreTest do
  use Jido.Harness.ReplayStore.ContractCase, adapter: Jido.Harness.ReplayStore.File

  test "reopening an empty retained store preserves its sequence watermark", context do
    options = %{journal_dir: context.base, disk_limit_bytes: 100}
    adapter = Jido.Harness.ReplayStore.File
    {:ok, handle} = adapter.open(context.resource, options)

    assert {:error, :record_too_large, handle} =
             adapter.append(handle, %{"sequence" => 8, "payload" => String.duplicate("x", 200)})

    assert :ok = adapter.close(handle)
    assert {:ok, reopened} = adapter.open(context.resource, options)
    assert {:ok, page, _} = adapter.read(reopened, 0, limits())
    assert page.next_cursor == 8
    assert page.gaps == [%{from: 1, to: 8, reason: :unavailable}]
  end

  test "small byte pages stop decoding after one fitting record and lookahead", context do
    adapter = Jido.Harness.ReplayStore.File
    {:ok, handle} = adapter.open(context.resource, %{journal_dir: context.base})
    handle = append(handle, 1..100)
    bytes = Record.bytes(record(1))

    {{:ok, page, _handle}, stats} =
      Jido.Harness.ReplayProbe.measure(fn -> adapter.read(handle, 0, limits(100, bytes)) end)

    assert page.records == [record(1)]
    assert page.next_cursor == 1
    assert stats.decoded_records == 2
  end

  test "reopen and append preserve valid records after a truncated tail", context do
    adapter = Jido.Harness.ReplayStore.File
    options = %{journal_dir: context.base}
    {:ok, handle} = adapter.open(context.resource, options)
    handle = append(handle, [1])
    File.write!(handle.journal.path, ~s({"sequence":2,"payload":"partial), [:append])
    assert :ok = adapter.close(handle)
    assert {:ok, handle} = adapter.open(context.resource, options)
    handle = append(handle, [3])
    assert {:ok, page, _} = adapter.read(handle, 0, limits())
    assert page.records == [record(1), record(3)]
    assert page.gaps == [%{from: 2, to: 2, reason: :unavailable}]
  end

  test "duplicate and out of order disk records cannot move the cursor back", context do
    adapter = Jido.Harness.ReplayStore.File
    options = %{journal_dir: context.base}
    {:ok, handle} = adapter.open(context.resource, options)
    handle = append(handle, [1, 3])
    File.write!(handle.journal.path, Jason.encode!(record(2)) <> "\n", [:append])
    assert {:ok, handle} = adapter.open(context.resource, options)
    handle = append(handle, [4])
    assert {:ok, page, _} = adapter.read(handle, 0, limits())
    assert page.records == [record(1), record(3), record(4)]
    assert page.next_cursor == 4
    assert page.gaps == [%{from: 2, to: 2, reason: :unavailable}]
  end
end

defmodule Jido.Harness.MemoryReplayStoreTest do
  use Jido.Harness.ReplayStore.ContractCase, adapter: Jido.Harness.ReplayStore.Memory
end

defmodule Jido.Harness.ETSReplayStoreTest do
  use Jido.Harness.ReplayStore.ContractCase, adapter: Jido.Harness.ReplayStore.ETS

  test "owner exit removes the private table" do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, handle} = Jido.Harness.ReplayStore.ETS.open(%{kind: :run, id: "owner", format_version: 1}, %{})
        send(parent, {:table, handle.data})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:table, table}
    assert :ets.info(table, :owner) == pid
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert :ets.info(table) == :undefined
  end
end
