defmodule Jido.Harness.EventLog do
  @moduledoc false

  alias Jido.Harness.{Buffer, ReplayStore}
  alias Jido.Harness.ReplayStore.{Memory, Page, Record}
  alias Jido.Harness.ReplayStore.File, as: FileStore

  @schema Zoi.struct(__MODULE__, %{
            module: Zoi.atom(),
            handle: Zoi.any() |> Zoi.nullish(),
            opened?: Zoi.boolean() |> Zoi.default(false),
            fallback: Zoi.any(),
            resource: Zoi.map(),
            latest_sequence: Zoi.integer() |> Zoi.default(0),
            write_failed?: Zoi.boolean() |> Zoi.default(false),
            status: Zoi.atom() |> Zoi.default(:healthy)
          })
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the resource event log schema."
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

  @doc "Validates storage configuration and opens storage with a bounded sanitized fallback."
  @spec open(atom(), String.t(), map(), term()) :: t()
  def open(kind, id, retention, config \\ Application.get_env(:jido_harness, :replay_store, {FileStore, %{}})) do
    {module, options} = configuration(config, retention)
    resource = %{kind: kind, id: id, format_version: 1}
    {:ok, fallback} = Memory.open(resource, %{max_bytes: Map.get(retention, :memory_bytes, 1_048_576)})
    log = %__MODULE__{module: module, resource: resource, fallback: fallback}

    case safe_open(module, resource, options) do
      {:ok, handle} ->
        log = %{log | handle: handle, opened?: true}
        %{log | latest_sequence: info(log).latest_sequence}

      {:error, _reason} ->
        error(log, :open)
        %{log | status: :degraded, write_failed?: true}
    end
  end

  defp configuration({module, options}, retention) when is_atom(module) and is_map(options) do
    options =
      if module == FileStore,
        do: file_options(options, retention),
        else: options

    callbacks = ReplayStore.behaviour_info(:callbacks)
    valid? = Code.ensure_loaded?(module) and Enum.all?(callbacks, fn {f, a} -> function_exported?(module, f, a) end)

    if not valid? or module.validate_options(options) != :ok,
      do: raise(ArgumentError, "invalid replay store module or options")

    {module, options}
  end

  defp configuration(_config, _retention), do: raise(ArgumentError, "replay_store must be {module, options_map}")

  defp file_options(options, retention) do
    keys = [:journal_dir, :segment_bytes, :disk_limit_bytes, :max_events]

    Application.get_env(:jido_harness, :process_manager, %{})
    |> Map.new()
    |> Map.take(keys)
    |> Map.merge(options)
    |> Map.merge(Map.take(retention, keys))
  end

  @doc "Creates the original event buffer used by the internal live path."
  @spec new_buffer(pos_integer()) :: Buffer.t()
  def new_buffer(memory_bytes), do: Buffer.new(memory_bytes)

  @doc "Prepares public replay once and retains original events only in the live buffer."
  @spec append(Buffer.t(), t(), map(), term()) :: {Buffer.t(), t()}
  def append(buffer, log, event, secrets \\ []) do
    record = Record.prepare(event, secrets)
    {_, fallback} = append_result(Memory.append(log.fallback, record))
    log = %{log | fallback: fallback, latest_sequence: max(log.latest_sequence, record["sequence"])}
    started = System.monotonic_time()

    log =
      if log.opened? do
        case safe(log.module, :append, [log.handle, record], log.handle) do
          {:ok, handle} ->
            %{log | handle: handle}

          {:error, :record_too_large, handle} ->
            %{log | handle: handle}

          {:error, _reason, handle} ->
            error(log, :append)
            %{log | handle: handle, write_failed?: true, status: :degraded}
        end
      else
        log
      end

    retained = info(log)
    telemetry(log, :append, started, Map.take(retained, [:retained_events, :retained_bytes]))
    {Buffer.append(buffer, event), log}
  end

  defp append_result({:ok, handle}), do: {:ok, handle}
  defp append_result({:error, reason, handle}), do: {reason, handle}

  @doc "Reads a bounded replay page, with the same data policy during storage failure."
  @spec replay(t(), non_neg_integer(), pos_integer(), pos_integer(), function()) :: {Page.t(), t()}
  def replay(log, cursor, count, bytes \\ 1_048_576, normalize \\ &Function.identity/1) do
    limits = %{max_events: count, max_bytes: bytes}
    started = System.monotonic_time()

    {page, log} =
      if log.opened? and not log.write_failed? do
        case read(log, cursor, limits, normalize) do
          {:ok, page, handle} when page.latest_sequence >= log.latest_sequence ->
            {page,
             %{log | handle: handle, status: :healthy, latest_sequence: max(log.latest_sequence, page.latest_sequence)}}

          {:ok, _page, _handle} ->
            error(log, :read)
            fallback(%{log | status: :degraded}, cursor, limits, normalize)

          {:error, _reason, handle} ->
            error(log, :read)
            fallback(%{log | handle: handle, status: :degraded}, cursor, limits, normalize)
        end
      else
        fallback(log, cursor, limits, normalize)
      end

    telemetry(log, :read, started, %{returned_records: length(page.records), gaps: length(page.gaps), bytes: page.bytes})

    {page, log}
  end

  defp read(log, cursor, limits, normalize) do
    case safe(log.module, :read, [log.handle, cursor, limits], log.handle) do
      {:ok, page, handle} -> {:ok, %{page | records: Enum.map(page.records, normalize)}, handle}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_record, log.handle}
  catch
    _, _ -> {:error, :invalid_record, log.handle}
  end

  defp fallback(log, cursor, limits, normalize) do
    fallback = %{log.fallback | latest: max(log.latest_sequence, log.fallback.latest)}
    {:ok, page, fallback} = Memory.read(fallback, cursor, limits)
    {%{page | records: Enum.map(page.records, normalize)}, %{log | fallback: fallback}}
  end

  @doc "Maps a page to the compatible ordered event list, including each missing range."
  @spec events(Page.t(), function(), function()) :: [map()]
  def events(page, record_fun, gap_fun) do
    records = Enum.map(page.records, record_fun)
    gaps = Enum.map(page.gaps, gap_fun)
    Enum.sort_by(records ++ gaps, & &1.sequence)
  end

  @doc "Returns storage-neutral status and retention metadata."
  @spec info(t()) :: map()
  def info(log) do
    info = if log.opened?, do: log.module.info(log.handle), else: Memory.info(log.fallback)
    true = valid_info?(info)
    info = if log.write_failed?, do: Map.merge(info, Map.delete(Memory.info(log.fallback), :directory)), else: info

    Map.merge(info, %{
      adapter: log.module,
      status: log.status,
      latest_sequence: max(info.latest_sequence, log.latest_sequence)
    })
  rescue
    _ -> fallback_info(log)
  catch
    _, _ -> fallback_info(log)
  end

  defp fallback_info(log) do
    Map.merge(Memory.info(log.fallback), %{
      adapter: log.module,
      status: :degraded,
      latest_sequence: max(log.latest_sequence, log.fallback.latest)
    })
  end

  defp valid_info?(%{oldest_sequence: oldest, latest_sequence: latest, retained_events: count, retained_bytes: bytes})
       when is_integer(latest) and latest >= 0 and is_integer(count) and count >= 0 and is_integer(bytes) and bytes >= 0,
       do: (is_nil(oldest) and count == 0) or (is_integer(oldest) and oldest > 0 and oldest <= latest and count > 0)

  defp valid_info?(_info), do: false

  @doc "Returns the optional file directory for compatibility."
  @spec dir(t()) :: String.t() | nil
  def dir(log), do: Map.get(info(log), :directory)

  @doc "Closes storage without deleting retained records."
  @spec close(t()) :: :ok | {:error, term()}
  def close(%{opened?: false}), do: :ok
  def close(log), do: cleanup(log, :close)

  @doc "Deletes retained storage and reports cleanup failures."
  @spec remove(t()) :: :ok | {:error, term()}
  def remove(%{opened?: false}), do: :ok
  def remove(log), do: cleanup(log, :delete)

  defp cleanup(log, operation) do
    case apply(log.module, operation, [log.handle]) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_callback_result}
    end
  rescue
    _ -> {:error, :callback_failed}
  catch
    _, _ -> {:error, :callback_failed}
  end

  defp safe_open(module, resource, options) do
    case module.open(resource, options) do
      {:ok, _handle} = result -> result
      {:error, _reason} = result -> result
      _ -> {:error, :invalid_callback_result}
    end
  rescue
    _ -> {:error, :callback_failed}
  catch
    _, _ -> {:error, :callback_failed}
  end

  defp safe(module, operation, arguments, handle) do
    result = apply(module, operation, arguments)

    if valid_result?(operation, result, arguments),
      do: result,
      else: {:error, :invalid_callback_result, handle}
  rescue
    _ -> {:error, :callback_failed, handle}
  catch
    _, _ -> {:error, :callback_failed, handle}
  end

  defp valid_result?(:append, {:ok, _handle}, _arguments), do: true
  defp valid_result?(_operation, {:error, _reason, _handle}, _arguments), do: true
  defp valid_result?(:read, {:ok, page, _handle}, [_previous, cursor, limits]), do: Page.valid?(page, cursor, limits)
  defp valid_result?(_operation, _result, _arguments), do: false

  defp error(log, operation) do
    :telemetry.execute([:jido, :harness, :replay_store, :error], %{count: 1}, %{
      adapter: log.module,
      operation: operation
    })
  end

  defp telemetry(log, operation, started, measurements) do
    :telemetry.execute(
      [:jido, :harness, :replay_store, operation],
      Map.put(measurements, :duration, System.monotonic_time() - started),
      %{adapter: log.module, kind: log.resource.kind, status: log.status}
    )
  end
end
