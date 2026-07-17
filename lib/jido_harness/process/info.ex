defmodule Jido.Harness.ProcessInfo do
  @moduledoc "A redacted snapshot of a managed OS process."

  @states [:starting, :running, :stopping, :exited, :failed, :cancelled, :timed_out]
  @schema Zoi.struct(
            __MODULE__,
            %{
              process_id: Zoi.string(),
              state: Zoi.enum(@states),
              started_at: Zoi.string(),
              finished_at: Zoi.string() |> Zoi.nullish(),
              os_pid: Zoi.integer() |> Zoi.nullish(),
              exit_status: Zoi.integer() |> Zoi.nullish(),
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

  @doc "Returns the validation schema for managed process snapshots."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs a managed process snapshot."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid process info", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs process information, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, info} -> info
      {:error, error} -> raise error
    end
  end

  @spec terminal?(t()) :: boolean()
  @doc "Returns whether the process reached a terminal state."
  def terminal?(%__MODULE__{state: state}), do: state in [:exited, :failed, :cancelled, :timed_out]
end
