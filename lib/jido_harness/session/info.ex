defmodule Jido.Harness.SessionInfo do
  @moduledoc "A redacted snapshot of a supervised interactive session."

  @states [:starting, :idle, :running, :awaiting_approval, :closing, :closed, :failed, :cancelled]
  @schema Zoi.struct(
            __MODULE__,
            %{
              session_id: Zoi.string(),
              provider: Zoi.atom(),
              provider_session_id: Zoi.string() |> Zoi.nullish(),
              state: Zoi.enum(@states),
              active_turn_id: Zoi.string() |> Zoi.nullish(),
              started_at: Zoi.string(),
              finished_at: Zoi.string() |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish(),
              journal_dir: Zoi.string() |> Zoi.nullish(),
              transport: Zoi.atom() |> Zoi.nullish(),
              output_cursor: Zoi.integer() |> Zoi.default(0),
              queued_turns: Zoi.integer() |> Zoi.default(0),
              pending_approvals: Zoi.integer() |> Zoi.default(0),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type state :: unquote(Enum.reduce(@states, &{:|, [], [&1, &2]}))
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for supervised session snapshots."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs a supervised session snapshot."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid session info", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs session information, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, info} -> info
      {:error, error} -> raise error
    end
  end

  @doc "Returns whether the session has emitted its terminal lifecycle event."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in [:closed, :failed, :cancelled]
end
