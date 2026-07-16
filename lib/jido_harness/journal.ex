defmodule Jido.Harness.Journal do
  @moduledoc false

  require Logger

  defstruct [
    :dir,
    :path,
    segment: 0,
    segment_bytes: 8 * 1_024 * 1_024,
    current_bytes: 0,
    total_bytes: 0,
    disk_limit_bytes: 256 * 1_024 * 1_024,
    failed?: false,
    available_from: 1
  ]

  @type t :: %__MODULE__{
          dir: String.t(),
          path: String.t(),
          segment: non_neg_integer(),
          segment_bytes: pos_integer(),
          current_bytes: non_neg_integer(),
          total_bytes: non_neg_integer(),
          disk_limit_bytes: pos_integer(),
          failed?: boolean(),
          available_from: pos_integer()
        }

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
         {:ok, state} <- create_segment(state) do
      {:ok, state}
    end
  end

  @spec append(t(), map()) :: {:ok, t()} | {:error, term(), t()}
  def append(%__MODULE__{failed?: true} = state, _record), do: {:error, :journal_unavailable, state}

  def append(%__MODULE__{} = state, record) when is_map(record) do
    with {:ok, json} <- Jason.encode(sanitize(record)),
         line = json <> "\n",
         {:ok, state} <- maybe_rotate(state, byte_size(line)),
         :ok <- File.write(state.path, line, [:append, :binary]) do
      state = %{
        state
        | current_bytes: state.current_bytes + byte_size(line),
          total_bytes: state.total_bytes + byte_size(line)
      }

      {:ok, prune(state)}
    else
      {:error, reason} ->
        Logger.warning("Jido.Harness journal disabled: #{inspect(reason)}")
        :telemetry.execute([:jido, :harness, :journal, :error], %{count: 1}, %{reason: reason})
        {:error, reason, %{state | failed?: true}}
    end
  end

  @spec replay(t(), non_neg_integer(), pos_integer()) :: {[map()], t()}
  def replay(%__MODULE__{failed?: true} = state, _cursor, _limit), do: {[], state}

  def replay(%__MODULE__{} = state, cursor, limit) do
    events =
      state.dir
      |> segment_paths()
      |> Stream.flat_map(&File.stream!(&1, :line, []))
      |> Stream.map(&Jason.decode/1)
      |> Stream.filter(&match?({:ok, %{}}, &1))
      |> Stream.map(fn {:ok, record} -> record end)
      |> Stream.filter(&(Map.get(&1, "sequence", 0) > cursor))
      |> Enum.take(limit)

    {events, state}
  rescue
    error ->
      :telemetry.execute([:jido, :harness, :journal, :error], %{count: 1}, %{reason: error})
      {[], %{state | failed?: true}}
  end

  @spec remove(t()) :: :ok | {:error, term()}
  def remove(%__MODULE__{dir: dir}), do: File.rm_rf(dir) |> normalize_rm()

  def default_base_dir do
    :filename.basedir(:user_cache, "jido_harness") |> to_string()
  end

  defp maybe_rotate(%__MODULE__{} = state, incoming) when state.current_bytes + incoming <= state.segment_bytes,
    do: {:ok, state}

  defp maybe_rotate(%__MODULE__{} = state, _incoming), do: create_segment(%{state | segment: state.segment + 1})

  defp create_segment(%__MODULE__{} = state) do
    path = Path.join(state.dir, String.pad_leading(Integer.to_string(state.segment), 8, "0") <> ".jsonl")

    with :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600) do
      {:ok, %{state | path: path, current_bytes: file_size(path)}}
    end
  end

  defp prune(%__MODULE__{total_bytes: total, disk_limit_bytes: limit} = state) when total <= limit, do: state

  defp prune(%__MODULE__{} = state) do
    case segment_paths(state.dir) do
      [oldest | rest] when oldest != state.path and rest != [] ->
        size = file_size(oldest)
        _ = File.rm(oldest)
        available_from = first_sequence(List.first(rest)) || state.available_from

        :telemetry.execute([:jido, :harness, :journal, :overflow], %{bytes: size}, %{
          journal_dir: state.dir,
          available_from: available_from
        })

        prune(%{state | total_bytes: max(0, state.total_bytes - size), available_from: available_from})

      _ ->
        state
    end
  end

  defp segment_paths(dir), do: dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.sort()

  defp first_sequence(nil), do: nil

  defp first_sequence(path) do
    path
    |> File.stream!(:line, [])
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"sequence" => sequence}} -> sequence
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
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
