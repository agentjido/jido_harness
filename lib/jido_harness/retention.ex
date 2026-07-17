defmodule Jido.Harness.Retention do
  @moduledoc false
  use GenServer

  @default_interval_ms 60_000
  @default_ttl_ms 24 * 60 * 60 * 1_000

  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule()
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    config = Application.get_env(:jido_harness, :process_manager, %{}) |> Map.new()
    ttl = Map.get(config, :terminal_ttl_ms, @default_ttl_ms)
    now = DateTime.utc_now()

    Jido.Harness.ProcessManager.list_processes()
    |> Enum.filter(&expired?(&1.finished_at, now, ttl))
    |> Enum.each(&Jido.Harness.ProcessManager.prune_process(&1.process_id))

    Jido.Harness.RunManager.list()
    |> Enum.filter(&expired?(&1.finished_at, now, ttl))
    |> Enum.each(&Jido.Harness.RunManager.prune(&1.run_id))

    Jido.Harness.SessionManager.list()
    |> Enum.filter(&expired?(&1.finished_at, now, ttl))
    |> Enum.each(&Jido.Harness.SessionManager.prune(&1.session_id))

    schedule(Map.get(config, :retention_sweep_ms, @default_interval_ms))
    {:noreply, state}
  end

  defp expired?(nil, _now, _ttl), do: false

  defp expired?(finished_at, now, ttl) do
    case DateTime.from_iso8601(finished_at) do
      {:ok, finished, _offset} -> DateTime.diff(now, finished, :millisecond) >= ttl
      _ -> false
    end
  end

  defp schedule(interval \\ @default_interval_ms), do: Process.send_after(self(), :sweep, interval)
end
