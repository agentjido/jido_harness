defmodule Jido.Harness.ReplayStore do
  @moduledoc """
  Storage contract for prepared, cursor-addressed harness records.

  The resource worker serializes calls. A resource is identified by its kind,
  ID, and record format version. The core assigns sequences and removes secrets
  and raw payloads before append. Adapters never receive execution requests.

  Reads use an exclusive sequence cursor and positive `:max_events` and
  `:max_bytes` limits. See `Jido.Harness.ReplayStore.Page` for gap and cursor
  rules. Append success means the next read can see the record, not that the
  write survives a crash. Repeating a retained record is safe; different data
  at that sequence is a conflict. An expired sequence can return
  `:expired_sequence`, because its original data can no longer be compared.

  Callbacks run in the resource worker and must finish promptly. An adapter
  that uses remote I/O must isolate that I/O and bound its queues and deadlines.
  A callback timeout alone cannot interrupt a blocked worker.

  Close releases handles without deleting records. Delete is explicit and
  idempotent. Persistent records do not restore provider execution or create a
  historical lookup API.
  """

  alias Jido.Harness.ReplayStore.Page

  @type resource :: %{kind: :process | :run | :session, id: String.t(), format_version: 1}
  @type limits :: %{max_events: pos_integer(), max_bytes: pos_integer()}
  @type replay_record :: %{required(String.t()) => term()}
  @type info :: %{
          optional(:directory) => String.t() | nil,
          oldest_sequence: pos_integer() | nil,
          latest_sequence: non_neg_integer(),
          retained_bytes: non_neg_integer(),
          retained_events: non_neg_integer()
        }

  @callback validate_options(map()) :: :ok | {:error, term()}
  @callback open(resource(), map()) :: {:ok, term()} | {:error, term()}
  @callback append(term(), replay_record()) :: {:ok, term()} | {:error, term(), term()}
  @callback read(term(), non_neg_integer(), limits()) :: {:ok, Page.t(), term()} | {:error, term(), term()}
  @callback info(term()) :: info()
  @callback close(term()) :: :ok | {:error, term()}
  @callback delete(term()) :: :ok | {:error, term()}

  @doc false
  @spec validate_resource(term()) :: :ok | {:error, :invalid_resource}
  def validate_resource(%{kind: kind, id: id, format_version: 1})
      when kind in [:process, :run, :session] and is_binary(id) and byte_size(id) > 0, do: :ok

  def validate_resource(_resource), do: {:error, :invalid_resource}

  @doc false
  @spec page_options(term()) :: {:ok, non_neg_integer(), map()} | {:error, term()}
  def page_options(options) do
    with {:ok, options} <- Jido.Harness.Validation.keyword_options(options),
         cursor = Keyword.get(options, :cursor, 0),
         count = Keyword.get(options, :limit, 100),
         bytes = Keyword.get(options, :max_bytes, 1_048_576),
         :ok <- validate_read(cursor, count, bytes) do
      {:ok, cursor, %{max_events: count, max_bytes: bytes}}
    else
      {:error, :invalid_replay_limits} ->
        {:error, Jido.Harness.Error.validation("invalid replay cursor, limit, or max_bytes")}

      error ->
        error
    end
  end

  @doc "Validates a page cursor and count and byte limits."
  @spec validate_read(term(), term(), term()) :: :ok | {:error, :invalid_replay_limits}
  def validate_read(cursor, count, bytes)
      when is_integer(cursor) and cursor >= 0 and is_integer(count) and count > 0 and count <= 10_000 and
             is_integer(bytes) and bytes > 0,
      do: :ok

  def validate_read(_cursor, _count, _bytes), do: {:error, :invalid_replay_limits}
end
