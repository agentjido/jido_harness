# Run with: mix run bench/replay_store.exs
# No provider process, credentials, or external service is used.
defmodule ReplayStoreBench do
  alias Jido.Harness.Buffer
  alias Jido.Harness.ReplayStore.{ETS, Memory}

  def run do
    count = positive_env("HARNESS_STORE_RECORDS", 16_000)
    reads = positive_env("HARNESS_STORE_READS", 1_000)
    budget = positive_env("HARNESS_STORE_BYTES", 4_194_304)

    IO.puts(
      Jason.encode!(%{
        environment: %{
          otp: System.otp_release(),
          elixir: System.version(),
          schedulers: System.schedulers_online(),
          word_size: :erlang.system_info(:wordsize)
        }
      })
    )

    # Warm shared code before measurements; each measured resource still has a new owner.
    for module <- [Buffer, Memory, ETS] do
      {pid, ref} = spawn_worker(module, 200, 100, 256, budget)

      receive do
        {^pid, :ready, _} -> :ok
      end

      send(pid, :cleanup)

      receive do
        {^pid, :clean, _} -> :ok
      end

      send(pid, :stop)

      receive do
        {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      end
    end

    for resources <- [1, 32], bytes <- [256, 4_096], module <- [Buffer, Memory, ETS] do
      count_per_resource = max(div(count, resources), 100)
      before_vm = :erlang.memory(:total)
      workers = for _ <- 1..resources, do: spawn_worker(module, count_per_resource, reads, bytes, budget)

      measurements =
        Enum.map(workers, fn {pid, ref} ->
          receive do
            {^pid, :ready, stats} -> {pid, ref, stats}
          after
            120_000 -> raise "benchmark timed out"
          end
        end)

      during_vm = :erlang.memory(:total)
      for {pid, _, _} <- measurements, do: send(pid, :cleanup)

      cleanup =
        Enum.map(measurements, fn {pid, _ref, _} ->
          receive do
            {^pid, :clean, stats} -> stats
          after
            10_000 -> raise "cleanup timed out"
          end
        end)

      after_vm = :erlang.memory(:total)

      for {pid, ref, _} <- measurements do
        send(pid, :stop)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
        end
      end

      stats = Enum.map(measurements, &elem(&1, 2))

      IO.puts(
        Jason.encode!(%{
          adapter: inspect(module),
          resources: resources,
          payload_bytes: bytes,
          records_per_resource: count_per_resource,
          reads_per_resource: reads,
          logical_limit_per_resource: budget,
          append_us_sum: sum(stats, :append_us),
          append_reductions: sum(stats, :append_reductions),
          tail_read_us_sum: sum(stats, :tail_read_us),
          tail_read_reductions: sum(stats, :tail_read_reductions),
          empty_read_us_sum: sum(stats, :empty_read_us),
          empty_read_reductions: sum(stats, :empty_read_reductions),
          retained_events: sum(stats, :retained_events),
          logical_bytes: sum(stats, :logical_bytes),
          process_memory_bytes: sum(stats, :process_memory_bytes),
          ets_memory_bytes: sum(stats, :ets_memory_bytes),
          cleanup_process_memory_bytes: sum(cleanup, :process_memory_bytes),
          cleanup_ets_memory_bytes: sum(cleanup, :ets_memory_bytes),
          max_queue_length: stats |> Enum.map(& &1.queue_length) |> Enum.max(),
          vm_before_bytes: before_vm,
          vm_retained_bytes: during_vm,
          vm_after_cleanup_bytes: after_vm
        })
      )
    end
  end

  defp spawn_worker(module, count, reads, bytes, budget) do
    parent = self()

    spawn_monitor(fn ->
      handle = open(module, budget)
      payload = String.duplicate("x", bytes)

      {append, handle} =
        measure(fn ->
          Enum.reduce(1..count, handle, fn n, handle ->
            record = %{"sequence" => n, "format_version" => 1, "payload" => payload}
            append(module, handle, record)
          end)
        end)

      {tail, _} =
        measure(fn ->
          for n <- 1..reads do
            cursor = count - rem(n, min(count, 100)) - 1
            read(module, handle, cursor)
          end
        end)

      {empty, _} = measure(fn -> for _ <- 1..reads, do: read(module, handle, count) end)
      :erlang.garbage_collect()

      stats = %{
        append_us: append.us,
        append_reductions: append.reductions,
        tail_read_us: tail.us,
        tail_read_reductions: tail.reductions,
        empty_read_us: empty.us,
        empty_read_reductions: empty.reductions
      }

      retained(parent, module, handle, stats)
    end)
  end

  defp retained(parent, module, handle, stats) do
    :erlang.garbage_collect()
    send(parent, {self(), :ready, Map.merge(stats, memory(module, handle))})

    receive do
      :cleanup ->
        if module != Buffer, do: module.delete(handle)
        cleaned(parent)
    end
  end

  defp cleaned(parent) do
    :erlang.garbage_collect()

    send(
      parent,
      {self(), :clean,
       %{process_memory_bytes: elem(Process.info(self(), :memory), 1), ets_memory_bytes: owned_ets_bytes()}}
    )

    receive do
      :stop -> :ok
    end
  end

  defp owned_ets_bytes do
    :ets.all()
    |> Enum.filter(&(:ets.info(&1, :owner) == self()))
    |> Enum.reduce(0, fn table, total -> total + :ets.info(table, :memory) * :erlang.system_info(:wordsize) end)
  end

  defp open(Buffer, budget), do: Buffer.new(budget)

  defp open(module, budget) do
    {:ok, handle} =
      module.open(%{kind: :run, id: "bench", format_version: 1}, %{max_bytes: budget, max_events: 100_000})

    handle
  end

  defp append(Buffer, handle, record), do: Buffer.append(handle, record)

  defp append(module, handle, record) do
    {:ok, handle} = module.append(handle, record)
    handle
  end

  # This is the original memory replay path, including its full-prefix scan.
  defp read(Buffer, handle, cursor),
    do: handle |> Buffer.events() |> Enum.filter(&(&1["sequence"] > cursor)) |> Enum.take(1)

  defp read(module, handle, cursor), do: module.read(handle, cursor, %{max_events: 1, max_bytes: 1_048_576})

  defp memory(module, handle) do
    {events, bytes} =
      if module == Buffer,
        do: {length(Buffer.events(handle)), handle.bytes},
        else: {module.info(handle).retained_events, module.info(handle).retained_bytes}

    :erlang.garbage_collect()
    ets = if module == ETS, do: :ets.info(handle.data, :memory) * :erlang.system_info(:wordsize), else: 0

    %{
      retained_events: events,
      logical_bytes: bytes,
      ets_memory_bytes: ets,
      process_memory_bytes: elem(Process.info(self(), :memory), 1),
      queue_length: elem(Process.info(self(), :message_queue_len), 1)
    }
  end

  defp measure(fun) do
    {_, before} = Process.info(self(), :reductions)
    {us, result} = :timer.tc(fun)
    {_, after_count} = Process.info(self(), :reductions)
    {%{us: us, reductions: after_count - before}, result}
  end

  defp sum(stats, key), do: Enum.reduce(stats, 0, &(&1[key] + &2))

  defp positive_env(name, default) do
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {value, ""} when value > 0 -> value
      _ -> raise "#{name} must be a positive integer"
    end
  end
end

ReplayStoreBench.run()
