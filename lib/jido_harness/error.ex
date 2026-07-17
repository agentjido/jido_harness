defmodule Jido.Harness.Error do
  @moduledoc """
  Provider-neutral API error with a stable category and message.

  A returned error means the API operation could not produce the requested
  value. Provider execution failure may instead be represented by an `{:ok,
  result}` whose terminal status is `:failed`, so callers should inspect result
  status as well as the outer tuple.
  """

  @categories [:validation, :configuration, :provider, :process, :execution, :timeout, :cancelled, :internal]
  @schema Zoi.struct(
            __MODULE__,
            %{
              category: Zoi.enum(@categories) |> Zoi.default(:internal),
              provider: Zoi.atom() |> Zoi.nullish(),
              run_id: Zoi.string() |> Zoi.nullish(),
              message: Zoi.string() |> Zoi.default("harness error"),
              details: Zoi.map() |> Zoi.default(%{}),
              cause: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type category :: unquote(Enum.reduce(@categories, &{:|, [], [&1, &2]}))
  @type t :: unquote(Zoi.type_spec(@schema))
  defexception Zoi.Struct.struct_fields(@schema)

  @doc "Returns the validation schema for normalized harness exceptions."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(category(), String.t(), keyword() | map()) :: t()
  @doc "Builds a normalized harness error."
  def new(category, message, attrs \\ %{}) when is_atom(category) and is_binary(message) do
    attrs = Map.new(attrs)

    case Zoi.parse(@schema, Map.merge(attrs, %{category: category, message: message})) do
      {:ok, error} -> error
      {:error, reason} -> raise ArgumentError, "invalid harness error: #{inspect(reason)}"
    end
  end

  @spec validation(String.t(), keyword() | map()) :: t()
  @doc "Builds a validation-category error."
  def validation(message, attrs \\ %{}), do: new(:validation, message, attrs)

  @spec execution(String.t(), keyword() | map()) :: t()
  @doc "Builds an execution-category error."
  def execution(message, attrs \\ %{}), do: new(:execution, message, attrs)

  @impl true
  @doc false
  def message(%__MODULE__{} = error) do
    prefix = if error.provider, do: "#{error.provider}: ", else: ""
    prefix <> error.message
  end
end
