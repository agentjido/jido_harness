defmodule Jido.Harness.ReplayStore.Memory do
  @moduledoc """
  Bounded replay storage in the resource worker's state.

  An ordered tree supports cursor reads without scanning the retained prefix.
  `:max_bytes` defaults to 1 MiB and `:max_events` to 10,000. The byte budget is
  JSON record bytes. Records disappear when the owner exits. Close is a no-op;
  deletion is handled by discarding the state.
  """
  @behaviour Jido.Harness.ReplayStore

  alias Jido.Harness.ReplayStore.{Page, Record}

  @schema Zoi.struct(__MODULE__, %{
            data: Zoi.any(),
            backend: Zoi.atom() |> Zoi.default(:tree),
            bytes: Zoi.integer() |> Zoi.default(0),
            count: Zoi.integer() |> Zoi.default(0),
            latest: Zoi.integer() |> Zoi.default(0),
            max_bytes: Zoi.integer() |> Zoi.default(1_048_576),
            max_events: Zoi.integer() |> Zoi.default(10_000)
          })
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the memory state schema."
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

  @impl true
  def validate_options(options) do
    if Map.keys(options) -- [:max_bytes, :max_events] == [] and
         Enum.all?(Map.values(options), &(is_integer(&1) and &1 > 0)),
       do: :ok,
       else: {:error, :invalid_memory_options}
  end

  @impl true
  def open(resource, options) do
    with :ok <- Jido.Harness.ReplayStore.validate_resource(resource), do: create(options, :tree)
  end

  @doc false
  @spec create(map(), :tree | :ets) :: {:ok, t()} | {:error, term()}
  def create(options, backend) do
    with :ok <- validate_options(options) do
      data = if backend == :ets, do: :ets.new(__MODULE__, [:ordered_set, :private]), else: :gb_trees.empty()
      {:ok, struct!(__MODULE__, Map.merge(options, %{data: data, backend: backend}))}
    end
  end

  @impl true
  def append(state, %{"sequence" => sequence} = record) when is_integer(sequence) and sequence > 0 do
    bytes = Record.bytes(record)

    cond do
      sequence <= state.latest -> duplicate(state, sequence, record)
      bytes > state.max_bytes -> {:error, :record_too_large, %{state | latest: sequence}}
      true -> {:ok, insert(state, sequence, record, bytes) |> trim()}
    end
  end

  def append(state, _record), do: {:error, :invalid_sequence, state}

  @impl true
  def read(state, cursor, limits) do
    with :ok <- Jido.Harness.ReplayStore.validate_read(cursor, limits.max_events, limits.max_bytes) do
      records = stream(state, cursor)
      {:ok, Page.build(records, cursor, info(state), limits), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def info(state) do
    %{
      oldest_sequence: oldest(state),
      latest_sequence: state.latest,
      retained_bytes: state.bytes,
      retained_events: state.count,
      directory: nil
    }
  end

  @impl true
  def close(_state), do: :ok

  @impl true
  def delete(%{backend: :ets, data: table}) do
    if :ets.info(table) != :undefined, do: :ets.delete(table)
    :ok
  end

  def delete(_state), do: :ok

  defp duplicate(state, sequence, record) do
    case lookup(state, sequence) do
      {^record, _bytes} -> {:ok, state}
      nil -> {:error, :expired_sequence, state}
      _ -> {:error, :sequence_conflict, state}
    end
  end

  defp lookup(%{backend: :tree, data: tree}, sequence) do
    case :gb_trees.lookup(sequence, tree) do
      {:value, value} -> value
      :none -> nil
    end
  end

  defp lookup(%{data: table}, sequence) do
    case :ets.lookup(table, sequence) do
      [{^sequence, record, bytes}] -> {record, bytes}
      [] -> nil
    end
  end

  defp insert(state, sequence, record, bytes) do
    data =
      case state.backend do
        :tree ->
          :gb_trees.insert(sequence, {record, bytes}, state.data)

        :ets ->
          :ets.insert(state.data, {sequence, record, bytes})
          state.data
      end

    %{state | data: data, bytes: state.bytes + bytes, count: state.count + 1, latest: sequence}
  end

  defp trim(state) when state.bytes <= state.max_bytes and state.count <= state.max_events, do: state

  defp trim(state) do
    sequence = oldest(state)
    {_record, bytes} = lookup(state, sequence)

    data =
      case state.backend do
        :tree ->
          :gb_trees.delete(sequence, state.data)

        :ets ->
          :ets.delete(state.data, sequence)
          state.data
      end

    trim(%{state | data: data, bytes: state.bytes - bytes, count: state.count - 1})
  end

  defp oldest(%{count: 0}), do: nil
  defp oldest(%{backend: :tree, data: tree}), do: tree |> :gb_trees.smallest() |> elem(0)
  defp oldest(%{data: table}), do: :ets.first(table)

  defp stream(%{backend: :tree, data: tree}, cursor) do
    Stream.unfold(:gb_trees.iterator_from(cursor + 1, tree), fn iterator ->
      case :gb_trees.next(iterator) do
        {_sequence, {record, size}, next} -> {{record, size}, next}
        :none -> nil
      end
    end)
  end

  defp stream(%{data: table}, cursor) do
    Stream.unfold(:ets.next(table, cursor), fn
      :"$end_of_table" ->
        nil

      sequence ->
        [{^sequence, record, bytes}] = :ets.lookup(table, sequence)
        {{record, bytes}, :ets.next(table, sequence)}
    end)
  end
end
