defmodule Jido.Harness.Process.DriverMessage do
  @moduledoc false

  @types [:started, :stdout, :stderr, :exited, :failed, :cancelled, :timed_out]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Zoi.enum(@types),
              timestamp: Zoi.string(),
              stream: Zoi.enum([:stdout, :stderr]) |> Zoi.nullish(),
              data: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type type :: unquote(Enum.reduce(@types, &{:|, [], [&1, &2]}))
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = attrs |> Map.new() |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

    case Zoi.parse(@schema, attrs) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, invalid(reason)}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, message} -> message
      {:error, error} -> raise error
    end
  end

  defp invalid(reason),
    do: Jido.Harness.Error.validation("invalid process driver message", details: %{reason: inspect(reason)})
end
