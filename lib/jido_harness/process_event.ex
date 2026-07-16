defmodule Jido.Harness.ProcessEvent do
  @moduledoc "A cursor-addressable event from a managed OS process."

  @enforce_keys [:process_id, :sequence, :timestamp, :type]
  defstruct [:process_id, :sequence, :timestamp, :type, :stream, :data, metadata: %{}]

  @type t :: %__MODULE__{
          process_id: String.t(),
          sequence: pos_integer(),
          timestamp: String.t(),
          type: :started | :stdout | :stderr | :exited | :failed | :cancelled | :timed_out | :replay_gap,
          stream: :stdout | :stderr | nil,
          data: term(),
          metadata: map()
        }

  @spec from_record(map()) :: t()
  @doc "Decodes an internal journal record into a process event."
  def from_record(record) do
    %__MODULE__{
      process_id: record["process_id"],
      sequence: record["sequence"],
      timestamp: record["timestamp"],
      type: to_existing_atom(record["type"]),
      stream: to_existing_atom(record["stream"]),
      data: decode_data(record["data"]),
      metadata: record["metadata"] || %{}
    }
  end

  defp to_existing_atom(nil), do: nil
  defp to_existing_atom(value) when is_atom(value), do: value
  defp to_existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)
  defp decode_data(%{"encoding" => "base64", "data" => data}), do: Base.decode64!(data)
  defp decode_data(value), do: value
end
