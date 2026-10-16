defmodule Jido.Harness.ReplayProbe do
  @moduledoc false

  @event [:jido, :harness, :journal, :replay]
  @counters [:decoded_records, :read_bytes, :segments_opened, :returned_records]

  def measure(fun) do
    key = make_ref()
    Process.put(key, Map.new([:calls, :max_decoded_records, :max_duration | @counters], &{&1, 0}))
    :ok = :telemetry.attach(key, @event, &__MODULE__.handle_event/4, {self(), key})

    try do
      {elapsed_us, result} = :timer.tc(fun)
      {result, Map.put(Process.get(key), :elapsed_us, elapsed_us)}
    after
      :telemetry.detach(key)
      Process.delete(key)
    end
  end

  def handle_event(_event, measurements, _metadata, {owner, key}) when owner == self() do
    stats = Enum.reduce(@counters, Process.get(key), &Map.update!(&2, &1, fn count -> count + measurements[&1] end))

    Process.put(key, %{
      stats
      | calls: stats.calls + 1,
        max_decoded_records: max(stats.max_decoded_records, measurements.decoded_records),
        max_duration: max(stats.max_duration, measurements.duration)
    })
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
