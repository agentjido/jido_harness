defmodule Jido.Harness.StructuredOutput do
  @moduledoc """
  A bounded JSON Schema contract for one finite harness run.

  Callers provide the schema as data. Harness adapters own any provider-specific
  serialization and must never accept a caller-supplied schema path.
  """

  alias Jido.Harness.{Error, JSONSchema}

  @default_max_output_bytes 262_144

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_id: Zoi.string(),
              schema: Zoi.map(),
              isolation: Zoi.literal(:ephemeral_read_only) |> Zoi.default(:ephemeral_read_only),
              max_output_bytes: Zoi.integer() |> Zoi.default(@default_max_output_bytes)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for structured-output contracts."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs a bounded structured-output contract."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, output} <- parse(attrs),
         :ok <- validate_schema_id(output.schema_id),
         :ok <- validate_output_limit(output.max_output_bytes),
         :ok <- JSONSchema.admit(output.schema) do
      {:ok, output}
    end
  end

  def new(_attrs), do: invalid(:structured_output, "structured_output must be a map or keyword list")

  @doc false
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = output) do
    with :ok <- validate_schema_id(output.schema_id),
         :ok <- validate_output_limit(output.max_output_bytes),
         :ok <- JSONSchema.admit(output.schema) do
      :ok
    end
  end

  @doc "Validates and constructs a structured-output contract, raising on error."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, output} -> output
      {:error, error} -> raise error
    end
  end

  defp parse(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, output} -> {:ok, output}
      {:error, _reason} -> invalid(:invalid_contract, "invalid structured_output contract")
    end
  end

  defp validate_schema_id(id) do
    if is_binary(id) and byte_size(id) in 1..128 and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/, id) do
      :ok
    else
      invalid(:invalid_schema_id, "structured_output schema_id is invalid")
    end
  end

  defp validate_output_limit(limit) when is_integer(limit) and limit in 1..1_048_576, do: :ok
  defp validate_output_limit(_limit), do: invalid(:invalid_output_limit, "structured_output byte limit is invalid")

  defp invalid(kind, message),
    do: {:error, Error.validation(message, details: %{failure_kind: kind, field: :structured_output})}
end
