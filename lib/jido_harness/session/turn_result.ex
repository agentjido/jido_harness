defmodule Jido.Harness.TurnResult do
  @moduledoc """
  Normalized terminal response from one interactive session turn.

  `status` is `:completed`, `:failed`, or `:interrupted`. The struct shares the
  normalized text, usage, event, metadata, and error vocabulary of
  `Jido.Harness.RunResult` while retaining session and turn identity.
  """

  alias Jido.Harness.Event

  @schema Zoi.struct(
            __MODULE__,
            %{
              session_id: Zoi.string(),
              turn_id: Zoi.string(),
              provider: Zoi.atom(),
              provider_session_id: Zoi.string() |> Zoi.nullish(),
              status: Zoi.enum([:completed, :failed, :interrupted]),
              text: Zoi.string() |> Zoi.default(""),
              text_truncated?: Zoi.boolean() |> Zoi.default(false),
              usage: Zoi.map() |> Zoi.default(%{}),
              events: Zoi.array(Event.schema()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{}),
              error: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for terminal turn results."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs a terminal turn result."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid turn result", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs a turn result, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
