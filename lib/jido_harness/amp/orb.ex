defmodule Jido.Harness.Amp.Orb do
  @moduledoc "A stable reference to an Amp thread that runs in an Orb."

  @schema Zoi.struct(
            __MODULE__,
            %{
              thread_id: Zoi.string(),
              url: Zoi.string()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for an Amp Orb reference."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs an Amp Orb reference."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, orb} ->
        {:ok, orb}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid Amp Orb reference", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs an Amp Orb reference, or raises an error."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, orb} -> orb
      {:error, error} -> raise error
    end
  end
end
