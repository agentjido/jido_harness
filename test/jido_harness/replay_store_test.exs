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
