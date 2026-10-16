defmodule Jido.Harness.TextTail do
  @moduledoc false

  @block_bytes 4_096
  @schema Zoi.struct(
            __MODULE__,
            %{
              chunks: Zoi.any() |> Zoi.default(:queue.new()),
              pending: Zoi.string() |> Zoi.default(""),
              bytes: Zoi.integer() |> Zoi.default(0),
              max_bytes: Zoi.integer(),
              truncated?: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for the internal text tail."
  def schema, do: @schema

  @doc "Creates an empty text tail with a positive byte limit."
  @spec new(pos_integer()) :: t()
  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    {:ok, tail} = Zoi.parse(@schema, %{max_bytes: max_bytes})
    tail
  end

  @doc "Retains bounded text chunks without rebuilding the full tail for each delta."
  @spec append(t(), String.t()) :: t()
  def append(tail, ""), do: tail

  def append(%__MODULE__{} = tail, text) when is_binary(text) do
    size = byte_size(text)

    if size >= tail.max_bytes do
      suffix = text |> binary_part(size - tail.max_bytes, tail.max_bytes) |> detach()

      %{
        tail
        | chunks: :queue.from_list([suffix]),
          pending: "",
          bytes: tail.max_bytes,
          truncated?: tail.truncated? or tail.bytes > 0 or size > tail.max_bytes
      }
    else
      pending = tail.pending <> text
      tail = %{tail | bytes: tail.bytes + size}

      tail =
        if byte_size(pending) >= @block_bytes,
          do: %{tail | chunks: :queue.in(pending, tail.chunks), pending: ""},
          else: %{tail | pending: pending}

      trim(tail)
    end
  end

  @doc "Materializes the retained valid UTF-8 suffix when a result is requested."
  @spec text(t()) :: String.t()
  def text(tail) do
    [:queue.to_list(tail.chunks), tail.pending] |> IO.iodata_to_binary() |> valid_suffix()
  end

  @doc "Replaces retained text and applies the existing byte limit."
  @spec replace(t(), String.t()) :: t()
  def replace(%__MODULE__{} = tail, text) when is_binary(text), do: new(tail.max_bytes) |> append(text)

  defp trim(%{bytes: bytes, max_bytes: max} = tail) when bytes <= max, do: tail

  defp trim(tail) do
    excess = tail.bytes - tail.max_bytes

    case :queue.out(tail.chunks) do
      {{:value, chunk}, rest} when byte_size(chunk) <= excess ->
        trim(%{tail | chunks: rest, bytes: tail.bytes - byte_size(chunk), truncated?: true})

      {{:value, chunk}, rest} ->
        suffix = chunk |> binary_part(excess, byte_size(chunk) - excess) |> detach()
        %{tail | chunks: :queue.in_r(suffix, rest), bytes: tail.max_bytes, truncated?: true}

      {:empty, _queue} ->
        pending = tail.pending |> binary_part(excess, tail.max_bytes) |> detach()
        %{tail | pending: pending, bytes: tail.max_bytes, truncated?: true}
    end
  end

  defp valid_suffix(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf8) do
      binary when is_binary(binary) -> value
      {:error, _valid, <<_invalid, rest::binary>>} -> valid_suffix(rest)
      {:incomplete, _valid, _rest} -> ""
    end
  end

  defp detach(value) do
    if :binary.referenced_byte_size(value) > max(@block_bytes, 2 * byte_size(value)),
      do: :binary.copy(value),
      else: value
  end
end
