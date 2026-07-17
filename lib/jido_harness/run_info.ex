defmodule Jido.Harness.RunInfo do
  @moduledoc "A snapshot of a supervised harness run."

  @states [:starting, :running, :completed, :failed, :cancelled]
  @schema Zoi.struct(
            __MODULE__,
            %{
              run_id: Zoi.string(),
              provider: Zoi.atom(),
              state: Zoi.enum(@states),
              started_at: Zoi.string(),
              finished_at: Zoi.string() |> Zoi.nullish(),
              provider_session_id: Zoi.string() |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish(),
              journal_dir: Zoi.string() |> Zoi.nullish(),
              output_cursor: Zoi.integer() |> Zoi.default(0),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type state :: unquote(Enum.reduce(@states, &{:|, [], [&1, &2]}))
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for supervised run snapshots."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs a supervised run snapshot."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid run info", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs run information, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, info} -> info
      {:error, error} -> raise error
    end
  end

  @spec terminal?(t()) :: boolean()
  @doc "Returns whether the run reached a terminal state."
  def terminal?(%__MODULE__{state: state}), do: state in [:completed, :failed, :cancelled]
end
