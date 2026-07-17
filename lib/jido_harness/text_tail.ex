defmodule Jido.Harness.TextTail do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              data: Zoi.string() |> Zoi.default(""),
              max_bytes: Zoi.integer(),
              truncated?: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

  @spec new(pos_integer()) :: t()
  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    {:ok, tail} = Zoi.parse(@schema, %{max_bytes: max_bytes})
    tail
  end

  @spec append(t(), String.t()) :: t()
  def append(%__MODULE__{} = tail, text) when is_binary(text) do
    if byte_size(text) >= tail.max_bytes do
      %{tail | data: trim(text, tail.max_bytes), truncated?: tail.truncated? or byte_size(text) > tail.max_bytes}
    else
      combined = tail.data <> text

      if byte_size(combined) > tail.max_bytes do
        %{tail | data: trim(combined, tail.max_bytes), truncated?: true}
      else
        %{tail | data: combined}
      end
    end
  end

  @spec replace(t(), String.t()) :: t()
  def replace(%__MODULE__{} = tail, text) when is_binary(text) do
    new(tail.max_bytes) |> append(text)
  end

  defp trim(value, max_bytes) do
    start = max(0, byte_size(value) - max_bytes)
    value |> binary_part(start, byte_size(value) - start) |> valid_suffix()
  end

  defp valid_suffix(value) do
    cond do
      String.valid?(value) -> value
      value == "" -> value
      true -> value |> binary_part(1, byte_size(value) - 1) |> valid_suffix()
    end
  end
end
