defmodule Jido.Harness.ReplayStore.File do
  @moduledoc """
  Default replay adapter for the bounded, segmented file journal.

  Options are `:journal_dir`, `:segment_bytes`, `:disk_limit_bytes`, and
  `:max_events` (default 1,000,000). Retention removes complete segments, so it
  can retain fewer records than the configured limit. Records larger than the
  disk budget are rejected. Writes do not promise fsync durability.

  Resource directories include the kind and ID. Close leaves files available
  for reopening; delete removes only that resource directory.
  """
  @behaviour Jido.Harness.ReplayStore

  alias Jido.Harness.Journal
  alias Jido.Harness.ReplayStore.{Page, Record}

  @schema Zoi.struct(__MODULE__, %{
            journal: Zoi.any(),
            latest: Zoi.integer() |> Zoi.default(0)
          })
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the file handle schema."
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
    valid? =
      Enum.all?(options, fn
        {:journal_dir, path} ->
          is_binary(path) and byte_size(path) > 0

        {key, value} when key in [:segment_bytes, :disk_limit_bytes, :max_events] ->
          is_integer(value) and value > 0

        _ ->
          false
      end)

    if valid?, do: :ok, else: {:error, :invalid_file_options}
  end

  @impl true
  def open(%{kind: kind, id: id, format_version: 1}, options)
      when kind in [:process, :run, :session] and is_binary(id) and byte_size(id) > 0 do
    with :ok <- validate_options(options),
         true <- Path.basename(id) == id and id not in [".", ".."] and not String.contains?(id, "\\"),
         {:ok, journal} <- Journal.open(Path.join(Atom.to_string(kind), id), options),
         {:ok, cursor} <- read_cursor(journal.dir) do
      state = %__MODULE__{journal: journal, latest: max(cursor, journal.latest_sequence)}
      with :ok <- keep_cursor(state), do: {:ok, state}
    else
      false -> {:error, :invalid_resource_id}
      error -> error
    end
  end

  def open(_resource, _options), do: {:error, :invalid_resource}

  @impl true
  def append(state, %{"sequence" => sequence} = record) when is_integer(sequence) and sequence > 0 do
    cond do
      sequence <= state.latest ->
        duplicate(state, sequence, record)

      Record.bytes(record) + 1 > state.journal.disk_limit_bytes ->
        reject(%{state | latest: sequence})

      true ->
        write(state, record, sequence)
    end
  end

  def append(state, _record), do: {:error, :invalid_sequence, state}

  defp write(state, record, sequence) do
    case Journal.append_prepared(state.journal, record) do
      {:ok, %{failed?: false} = journal} ->
        state = %{state | journal: journal, latest: sequence}

        case keep_cursor(state) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end

      {:ok, journal} ->
        {:error, :retention_failed, %{state | journal: journal, latest: sequence}}

      {:error, reason, journal} ->
        {:error, reason, %{state | journal: journal, latest: sequence}}
    end
  end

  defp reject(state) do
    case write_cursor(state) do
      :ok -> {:error, :record_too_large, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Persist progress if retention leaves no record from which it can be rebuilt.
  defp keep_cursor(%{journal: %{retained_events: 0}} = state), do: write_cursor(state)
  defp keep_cursor(_state), do: :ok

  defp write_cursor(state) do
    path = Path.join(state.journal.dir, ".cursor")
    data = Jason.encode!(%{format_version: 1, latest_sequence: state.latest})

    with :ok <- Elixir.File.write(path <> ".tmp", data),
         :ok <- Elixir.File.chmod(path <> ".tmp", 0o600),
         :ok <- Elixir.File.rename(path <> ".tmp", path),
         do: :ok
  end

  defp read_cursor(directory) do
    case Elixir.File.read(Path.join(directory, ".cursor")) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, %{"format_version" => 1, "latest_sequence" => value}} when is_integer(value) and value >= 0 ->
            {:ok, value}

          _ ->
            {:error, :invalid_store_cursor}
        end

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp duplicate(state, sequence, record) do
    {records, journal} = Journal.replay(state.journal, sequence - 1, 1)
    state = %{state | journal: journal}

    if journal.failed? or journal.read_failed? do
      {:error, :journal_unavailable, state}
    else
      case records do
        [^record] -> {:ok, state}
        [%{"sequence" => ^sequence}] -> {:error, :sequence_conflict, state}
        _ -> {:error, :expired_sequence, state}
      end
    end
  end

  @impl true
  def read(state, cursor, limits) do
    with :ok <- Jido.Harness.ReplayStore.validate_read(cursor, limits.max_events, limits.max_bytes) do
      {records, journal} = Journal.replay(state.journal, cursor, limits.max_events + 1, limits.max_bytes)
      state = %{state | journal: journal}

      if journal.failed? or journal.read_failed?,
        do: {:error, :journal_unavailable, state},
        else: {:ok, Page.build(records, cursor, info(state), limits), state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def info(state) do
    %{
      oldest_sequence: if(state.journal.retained_events > 0, do: state.journal.available_from),
      latest_sequence: state.latest,
      retained_bytes: state.journal.total_bytes,
      retained_events: state.journal.retained_events,
      directory: state.journal.dir
    }
  end

  @impl true
  def close(_state), do: :ok

  @impl true
  def delete(state), do: Journal.remove(state.journal)
end
