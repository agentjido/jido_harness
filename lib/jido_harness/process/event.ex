defmodule Jido.Harness.ProcessEvent do
  @moduledoc "A cursor-addressable event from a managed OS process."

  @types [:started, :stdout, :stderr, :exited, :failed, :cancelled, :timed_out, :replay_gap]
  @schema Zoi.struct(
            __MODULE__,
            %{
              process_id: Zoi.string(),
              sequence: Zoi.integer(),
              timestamp: Zoi.string(),
              type: Zoi.enum(@types),
              stream: Zoi.enum([:stdout, :stderr]) |> Zoi.nullish(),
              data: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for managed process events."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs a managed process event."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, invalid(reason)}
    end
  end

  @doc "Validates and constructs a process event, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, event} -> event
      {:error, error} -> raise error
    end
  end

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
  defp invalid(reason), do: Jido.Harness.Error.validation("invalid process event", details: %{reason: inspect(reason)})
end
