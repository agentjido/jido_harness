defmodule Jido.Harness.Buffer do
  @moduledoc false

  defstruct events: :queue.new(), bytes: 0, max_bytes: 1_048_576

  def new(max_bytes), do: %__MODULE__{max_bytes: max_bytes}

  def append(%__MODULE__{} = buffer, event) do
    size = event |> :erlang.term_to_binary() |> byte_size()
    buffer = %{buffer | events: :queue.in({event, size}, buffer.events), bytes: buffer.bytes + size}
    trim(buffer)
  end

  def events(%__MODULE__{} = buffer), do: for({event, _size} <- :queue.to_list(buffer.events), do: event)

  defp trim(%__MODULE__{bytes: bytes, max_bytes: max} = buffer) when bytes <= max, do: buffer

  defp trim(%__MODULE__{} = buffer) do
    case :queue.out(buffer.events) do
      {{:value, {_event, size}}, queue} -> trim(%{buffer | events: queue, bytes: buffer.bytes - size})
      {:empty, _queue} -> %{buffer | bytes: 0}
    end
  end
end
