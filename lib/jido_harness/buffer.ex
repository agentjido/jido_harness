defmodule Jido.Harness.Buffer do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              events: Zoi.any() |> Zoi.default(:queue.new()),
              bytes: Zoi.integer() |> Zoi.default(0),
              max_bytes: Zoi.integer() |> Zoi.default(1_048_576)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

  def new(max_bytes) do
    case Zoi.parse(@schema, %{max_bytes: max_bytes}) do
      {:ok, buffer} when is_integer(max_bytes) and max_bytes > 0 -> buffer
      _ -> raise ArgumentError, "max_bytes must be a positive integer"
    end
  end

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
