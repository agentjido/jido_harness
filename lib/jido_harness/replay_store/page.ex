defmodule Jido.Harness.ReplayStore.Page do
  @moduledoc """
  One bounded replay page, after an exclusive sequence cursor.

  `records` are ordered. `gaps` are disjoint inclusive ranges with `from`, `to`,
  and `reason`. `:unavailable` covers retention, rejected appends, and unavailable
  storage. `:page_limit` means a retained record exceeds this read's byte limit;
  a later read with a larger limit can still return it.

  `next_cursor` covers every returned record and reported gap. Pass it to the
  next read. It never moves backwards, including reads beyond the latest known
  sequence. An empty retained history can still report a gap and advance.

  `oldest_sequence` is nil when no records remain. `latest_sequence` includes
  rejected records known to the live handle. Gaps are bounded by the page's
  progress; they do not claim that later records are missing.

  Count limits bound inspected records, including records skipped for size.
  Bytes count JSON record bytes, without separators. Metadata is not included.
  These logical limits do not measure actual VM, ETS, or filesystem memory.
  """

  alias Jido.Harness.ReplayStore.Record

  @schema Zoi.struct(__MODULE__, %{
            records: Zoi.list(Zoi.any()) |> Zoi.default([]),
            gaps: Zoi.list(Zoi.any()) |> Zoi.default([]),
            next_cursor: Zoi.integer() |> Zoi.default(0),
            oldest_sequence: Zoi.integer() |> Zoi.nullish(),
            latest_sequence: Zoi.integer() |> Zoi.default(0),
            bytes: Zoi.integer() |> Zoi.default(0)
          })
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the page schema."
  def schema, do: @schema

  @doc "Constructs validated storage state."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attributes), do: Zoi.parse(@schema, Map.new(attributes))

  @doc "Constructs storage state, raising if attributes are invalid."
  @spec new!(map() | keyword()) :: t()
  def new!(attributes) do
    case new(attributes) do
      {:ok, value} -> value
      {:error, _reason} -> raise ArgumentError, "invalid storage state"
    end
  end

  @doc false
  @spec valid?(term(), non_neg_integer(), map()) :: boolean()
  def valid?(%__MODULE__{} = page, cursor, limits) do
    is_list(page.records) and is_list(page.gaps) and
      is_integer(page.bytes) and page.bytes >= 0 and page.bytes <= limits.max_bytes and
      is_integer(page.latest_sequence) and page.latest_sequence >= 0 and
      is_integer(page.next_cursor) and page.next_cursor >= cursor and
      page.next_cursor <= max(cursor, page.latest_sequence) and
      (page.latest_sequence <= cursor or page.next_cursor > cursor) and
      (is_nil(page.oldest_sequence) or
         (is_integer(page.oldest_sequence) and page.oldest_sequence > 0 and
            page.oldest_sequence <= page.latest_sequence)) and
      length(page.records) <= limits.max_events and length(page.gaps) <= limits.max_events + 1 and
      valid_ranges?(page.records, page.gaps, cursor, page.next_cursor, limits.max_events)
  end

  def valid?(_page, _cursor, _limits), do: false

  defp valid_ranges?([], [], cursor, last, remaining), do: cursor == last and remaining >= 0

  defp valid_ranges?([%{"sequence" => sequence, "format_version" => 1} | records], gaps, cursor, last, remaining)
       when sequence == cursor + 1 and remaining > 0,
       do: valid_ranges?(records, gaps, sequence, last, remaining - 1)

  defp valid_ranges?(records, [%{from: first, to: last, reason: reason} | gaps], cursor, final, remaining)
       when first == cursor + 1 and is_integer(last) and last >= first and reason in [:unavailable, :page_limit] do
    remaining = if reason == :page_limit, do: remaining - (last - first + 1), else: remaining
    remaining >= 0 and valid_ranges?(records, gaps, last, final, remaining)
  end

  defp valid_ranges?(_records, _gaps, _cursor, _last, _remaining), do: false

  @doc false
  @spec build(Enumerable.t(), non_neg_integer(), map(), map()) :: t()
  def build(records, cursor, info, limits) do
    initial = %{records: [], gaps: [], cursor: cursor, bytes: 0, count: 0, complete?: true}

    result = Enum.reduce_while(records, initial, &consume(&1, &2, limits))
    result = if result.complete?, do: gap(result, info.latest_sequence, :unavailable), else: result

    %__MODULE__{
      records: Enum.reverse(result.records),
      gaps: Enum.reverse(result.gaps),
      next_cursor: result.cursor,
      oldest_sequence: info.oldest_sequence,
      latest_sequence: info.latest_sequence,
      bytes: result.bytes
    }
  end

  defp consume(_record, %{count: count} = acc, %{max_events: limit}) when count >= limit,
    do: {:halt, %{acc | complete?: false}}

  defp consume(record, acc, limits) when is_map(record), do: consume({record, Record.bytes(record)}, acc, limits)

  defp consume({record, size}, acc, limits) do
    sequence = Map.fetch!(record, "sequence")
    acc = gap(acc, sequence - 1, :unavailable)

    cond do
      size > limits.max_bytes ->
        {:cont, %{gap(acc, sequence, :page_limit) | count: acc.count + 1}}

      acc.bytes + size > limits.max_bytes ->
        {:halt, %{acc | complete?: false}}

      true ->
        {:cont,
         %{acc | records: [record | acc.records], cursor: sequence, bytes: acc.bytes + size, count: acc.count + 1}}
    end
  end

  defp gap(acc, last, _reason) when last <= acc.cursor, do: acc

  defp gap(acc, last, reason) do
    range = %{from: acc.cursor + 1, to: last, reason: reason}

    gaps =
      case acc.gaps do
        [%{to: previous, reason: ^reason} = head | rest] when previous == acc.cursor ->
          [%{head | to: last} | rest]

        rest ->
          [range | rest]
      end

    %{acc | gaps: gaps, cursor: last}
  end
end
