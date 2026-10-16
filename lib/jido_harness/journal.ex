defmodule Jido.Harness.Journal do
  @moduledoc false

  require Logger

  alias Jido.Harness.Redaction
  alias Jido.Harness.Journal.Index

  @read_ahead 65_536

  @schema Zoi.struct(
            __MODULE__,
            %{
              dir: Zoi.string() |> Zoi.nullish(),
              path: Zoi.string() |> Zoi.nullish(),
              segment: Zoi.integer() |> Zoi.default(0),
              segment_bytes: Zoi.integer() |> Zoi.default(8 * 1_024 * 1_024),
              current_bytes: Zoi.integer() |> Zoi.default(0),
              total_bytes: Zoi.integer() |> Zoi.default(0),
              disk_limit_bytes: Zoi.integer() |> Zoi.default(256 * 1_024 * 1_024),
              failed?: Zoi.boolean() |> Zoi.default(false),
              read_failed?: Zoi.boolean() |> Zoi.default(false),
              latest_sequence: Zoi.integer() |> Zoi.default(0),
              segments: Zoi.map() |> Zoi.default(%{}),
              available_from: Zoi.integer() |> Zoi.default(1)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for internal journal state."
  def schema, do: @schema

  @doc "Creates private journal files with configured segment and disk limits."
  @spec open(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def open(id, options \\ %{}) do
    config =
      Application.get_env(:jido_harness, :process_manager, %{})
      |> Map.new()
      |> Map.merge(Map.new(options))

    base_dir = Map.get(config, :journal_dir, default_base_dir())
    dir = Path.join(base_dir, id)

    with :ok <- File.mkdir_p(base_dir),
         :ok <- File.chmod(base_dir, 0o700),
         :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         state <- %__MODULE__{
           dir: dir,
           segment_bytes: Map.get(config, :segment_bytes, 8 * 1_024 * 1_024),
           disk_limit_bytes: Map.get(config, :disk_limit_bytes, 256 * 1_024 * 1_024)
         },
         {:ok, state} <- load_or_create(state) do
      {:ok, state}
    end
  end

  @doc "Writes a redacted JSON record, rotates segments, and enforces retention limits."
  @spec append(t(), map(), [String.t()] | Redaction.prepared()) :: {:ok, t()} | {:error, term(), t()}
  def append(state, record, secrets \\ [])
  def append(%__MODULE__{failed?: true} = state, _record, _secrets), do: {:error, :journal_unavailable, state}

  def append(%__MODULE__{} = state, record, secrets) when is_map(record) do
    sequence = Map.get(record, :sequence, Map.get(record, "sequence"))

    if is_integer(sequence) and sequence > state.latest_sequence do
      append_record(state, record, sequence, secrets)
    else
      {:error, :invalid_sequence, state}
    end
  end

  defp append_record(state, record, sequence, secrets) do
    with {:ok, json} <- Jason.encode(record |> Redaction.redact(secrets) |> sanitize()),
         line = json <> "\n",
         {:ok, state} <- maybe_rotate(state, byte_size(line)),
         :ok <- File.write(state.path, line, [:append, :binary]) do
      state = %{
        state
        | current_bytes: state.current_bytes + byte_size(line),
          total_bytes: state.total_bytes + byte_size(line),
          latest_sequence: sequence,
          segments: Map.update!(state.segments, state.segment, &Index.append(&1, sequence, byte_size(line)))
      }

      {:ok, prune(state)}
    else
      {:error, reason} ->
        Logger.warning("Jido.Harness journal disabled: #{inspect(reason)}")
        :telemetry.execute([:jido, :harness, :journal, :error], %{count: 1}, %{reason: reason})
        {:error, reason, %{state | failed?: true}}
    end
  end

  @doc "Seeks near a sequence cursor; read errors leave future writes enabled."
  @spec replay(t(), non_neg_integer(), pos_integer()) :: {[map()], t()}
  def replay(%__MODULE__{failed?: true} = state, _cursor, _limit), do: {[], state}

  def replay(%__MODULE__{} = state, cursor, limit) do
    started = System.monotonic_time()
    initial = %{records: [], remaining: limit, decoded_records: 0, read_bytes: 0, segments_opened: 0}

    result =
      if cursor >= state.latest_sequence do
        {:ok, initial}
      else
        state.segments
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.filter(fn {_number, segment} -> segment.last > cursor end)
        |> Enum.reduce_while({:ok, initial}, fn {_number, segment}, {:ok, acc} ->
          case read_segment(segment, cursor, acc) do
            {:ok, %{remaining: 0} = acc} -> {:halt, {:ok, acc}}
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, _reason, _acc} = error -> {:halt, error}
          end
        end)
      end

    {events, state, stats} =
      case result do
        {:ok, acc} ->
          {Enum.reverse(acc.records), %{state | read_failed?: false}, acc}

        {:error, reason, acc} ->
          :telemetry.execute([:jido, :harness, :journal, :error], %{count: 1}, %{reason: reason})
          {[], %{state | read_failed?: true}, acc}
      end

    measurements =
      stats
      |> Map.take([:decoded_records, :read_bytes, :segments_opened])
      |> Map.merge(%{duration: System.monotonic_time() - started, returned_records: length(events)})

    :telemetry.execute([:jido, :harness, :journal, :replay], measurements, %{
      journal_dir: state.dir,
      cursor: cursor,
      limit: limit,
      read_failed?: state.read_failed?
    })

    {events, state}
  end

  defp read_segment(segment, cursor, acc) do
    case File.open(segment.path, [:read, :binary, :raw, read_ahead: @read_ahead], fn device ->
           acc = %{acc | segments_opened: acc.segments_opened + 1}

           case :file.position(device, Index.offset(segment, cursor)) do
             {:ok, _offset} -> read_records(device, cursor, acc)
             {:error, reason} -> {:error, reason, acc}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason, acc}
    end
  end

  defp read_records(_device, _cursor, %{remaining: 0} = acc), do: {:ok, acc}

  defp read_records(device, cursor, acc) do
    case :file.read_line(device) do
      {:ok, line} ->
        acc = %{acc | decoded_records: acc.decoded_records + 1, read_bytes: acc.read_bytes + byte_size(line)}

        acc =
          case Jason.decode(line) do
            {:ok, %{"sequence" => sequence} = record} when is_integer(sequence) and sequence > cursor ->
              %{acc | records: [record | acc.records], remaining: acc.remaining - 1}

            _other ->
              acc
          end

        read_records(device, cursor, acc)

      :eof ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  @doc "Removes the journal directory and reports filesystem errors."
  @spec remove(t()) :: :ok | {:error, term()}
  def remove(%__MODULE__{dir: dir}), do: File.rm_rf(dir) |> normalize_rm()

  @doc "Returns the application journal directory below the user cache."
  def default_base_dir do
    :filename.basedir(:user_cache, "jido_harness") |> to_string()
  end

  defp maybe_rotate(%__MODULE__{} = state, incoming) when state.current_bytes + incoming <= state.segment_bytes,
    do: {:ok, state}

  defp maybe_rotate(%__MODULE__{} = state, _incoming), do: create_segment(%{state | segment: state.segment + 1})

  defp create_segment(%__MODULE__{} = state) do
    path = Path.join(state.dir, String.pad_leading(Integer.to_string(state.segment), 8, "0") <> ".jsonl")

    with {:ok, :ok} <- File.open(path, [:write, :binary, :exclusive], fn _device -> :ok end),
         :ok <- File.chmod(path, 0o600) do
      {:ok, %{state | path: path, current_bytes: 0, segments: Map.put(state.segments, state.segment, Index.new(path))}}
    end
  end

  # Index an existing journal once when it is opened, never on each poll.
  defp load_or_create(state) do
    case segment_paths(state.dir) do
      [] ->
        create_segment(state)

      paths ->
        state =
          Enum.reduce(paths, state, fn path, state ->
            {number, ""} = Integer.parse(Path.basename(path, ".jsonl"))

            segment =
              Enum.reduce(File.stream!(path, :line, []), Index.new(path), fn line, segment ->
                sequence =
                  case Jason.decode(line) do
                    {:ok, %{"sequence" => sequence}} when is_integer(sequence) and sequence > segment.last -> sequence
                    _other -> nil
                  end

                Index.append(segment, sequence, byte_size(line))
              end)

            %{
              state
              | segment: number,
                path: path,
                current_bytes: segment.bytes,
                total_bytes: state.total_bytes + segment.bytes,
                latest_sequence: max(state.latest_sequence, segment.last),
                segments: Map.put(state.segments, number, segment)
            }
          end)

        first = state.segments |> Enum.min_by(&elem(&1, 0)) |> elem(1)
        {:ok, prune(%{state | available_from: first.first || 1})}
    end
  rescue
    error -> {:error, error}
  end

  defp prune(%__MODULE__{total_bytes: total, disk_limit_bytes: limit} = state) when total <= limit, do: state

  defp prune(%__MODULE__{} = state) do
    case Enum.sort_by(state.segments, &elem(&1, 0)) do
      [{number, oldest}, {_next_number, next} | _rest] when number != state.segment ->
        case File.rm(oldest.path) do
          :ok ->
            available_from = next.first || state.available_from

            :telemetry.execute([:jido, :harness, :journal, :overflow], %{bytes: oldest.bytes}, %{
              journal_dir: state.dir,
              available_from: available_from
            })

            prune(%{
              state
              | total_bytes: max(0, state.total_bytes - oldest.bytes),
                available_from: available_from,
                segments: Map.delete(state.segments, number)
            })

          {:error, reason} ->
            :telemetry.execute([:jido, :harness, :journal, :error], %{count: 1}, %{reason: reason})
            %{state | failed?: true}
        end

      _ ->
        state
    end
  end

  # Listed, not matched with a wildcard: a Windows path has backslashes,
  # which a wildcard reads as escapes and then matches nothing.
  defp segment_paths(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names |> Enum.filter(&String.ends_with?(&1, ".jsonl")) |> Enum.sort() |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp sanitize(%_{} = struct), do: struct |> Map.from_struct() |> sanitize()
  defp sanitize(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), sanitize(value)} end)
  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  defp sanitize(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: %{"encoding" => "base64", "data" => Base.encode64(value)})

  defp sanitize(value) when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize(value), do: inspect(value, limit: 50, printable_limit: 2_000)

  defp normalize_rm({:ok, _files}), do: :ok
  defp normalize_rm({:error, reason, _file}), do: {:error, reason}
end
