defmodule Jido.Harness.EventLog do
  @moduledoc false

  alias Jido.Harness.{Buffer, Journal, Redaction}

  @spec open(String.t(), map()) :: Journal.t() | nil
  def open(owner_id, retention) do
    case Journal.open(owner_id, retention) do
      {:ok, journal} ->
        journal

      {:error, reason} ->
        :telemetry.execute(
          [:jido, :harness, :journal, :error],
          %{count: 1},
          %{owner_id: owner_id, reason: reason}
        )

        nil
    end
  end

  @spec new_buffer(pos_integer()) :: Buffer.t()
  def new_buffer(memory_bytes), do: Buffer.new(memory_bytes)

  @spec append(Buffer.t(), Journal.t() | nil, term(), [String.t()]) :: {Buffer.t(), Journal.t() | nil}
  def append(buffer, journal, event, secrets \\ []) do
    persisted = event |> Map.from_struct() |> Map.put(:raw, nil) |> Redaction.redact(secrets)

    journal =
      case journal do
        nil ->
          nil

        journal ->
          case Journal.append(journal, persisted) do
            {:ok, updated} -> updated
            {:error, _reason, updated} -> updated
          end
      end

    {Buffer.append(buffer, event), journal}
  end

  @spec replay(Buffer.t(), Journal.t() | nil, non_neg_integer(), pos_integer()) ::
          {[term()], Journal.t() | nil, pos_integer()}
  def replay(_buffer, %Journal{failed?: false} = journal, cursor, limit) do
    {records, journal} = Journal.replay(journal, cursor, limit)
    {records, journal, journal.available_from}
  end

  def replay(buffer, journal, cursor, limit) do
    records = buffer |> Buffer.events() |> Enum.filter(&(&1.sequence > cursor)) |> Enum.take(limit)
    available_from = if records == [], do: cursor + 1, else: hd(records).sequence
    {records, journal, available_from}
  end

  @spec remove(Journal.t() | nil) :: :ok | {:error, term()}
  def remove(nil), do: :ok
  def remove(journal), do: Journal.remove(journal)

  @spec dir(Journal.t() | nil) :: String.t() | nil
  def dir(nil), do: nil
  def dir(journal), do: journal.dir
end
