defmodule Jido.Harness.AdapterSpec do
  @moduledoc "Static description of a harness adapter."

  alias Jido.Harness.{Capabilities, SessionTransportSpec}

  @schema Zoi.struct(
            __MODULE__,
            %{
              provider: Zoi.atom(),
              name: Zoi.string(),
              executable: Zoi.string(),
              install: Zoi.map() |> Zoi.nullish(),
              docs_url: Zoi.string() |> Zoi.nullish(),
              default_session_transport: Zoi.atom() |> Zoi.nullish(),
              capabilities: Capabilities.schema() |> Zoi.default(%Capabilities{}),
              session_transports: Zoi.array(SessionTransportSpec.schema()) |> Zoi.default([]),
              normalized_options: Zoi.array(Zoi.atom()) |> Zoi.default([]),
              normalized_values: Zoi.map(Zoi.atom(), Zoi.array(Zoi.any())) |> Zoi.default(%{}),
              provider_options: Zoi.array(Zoi.atom()) |> Zoi.default([]),
              request_defaults: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the schema for declarative adapter metadata."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs adapter metadata."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, spec} <- Zoi.parse(@schema, Map.new(attrs)),
         :ok <- validate_transports(spec),
         :ok <- validate_option_names(spec) do
      {:ok, spec}
    else
      {:error, %Jido.Harness.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid adapter specification", details: %{reason: inspect(reason)})}
    end
  end

  @doc "Validates and constructs adapter metadata, raising on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, error} -> raise error
    end
  end

  defp validate_transports(%__MODULE__{} = spec) do
    names = Enum.map(spec.session_transports, & &1.name)
    duplicate = names -- Enum.uniq(names)
    mismatched = Enum.find(spec.session_transports, &(&1.capabilities.transport != &1.name))

    cond do
      duplicate != [] ->
        invalid("session transport names must be unique", %{duplicates: Enum.uniq(duplicate)})

      spec.session_transports == [] and not is_nil(spec.default_session_transport) ->
        invalid("default session transport requires a declared transport")

      spec.session_transports != [] and is_nil(spec.default_session_transport) ->
        invalid("adapters with session transports must declare a default")

      spec.default_session_transport not in names and not is_nil(spec.default_session_transport) ->
        invalid("default session transport is not declared", %{transport: spec.default_session_transport})

      mismatched ->
        invalid("transport name and capability transport must match", %{
          name: mismatched.name,
          capability_transport: mismatched.capabilities.transport
        })

      true ->
        :ok
    end
  end

  defp validate_option_names(%__MODULE__{} = spec) do
    duplicate_normalized = spec.normalized_options -- Enum.uniq(spec.normalized_options)
    duplicate_provider = spec.provider_options -- Enum.uniq(spec.provider_options)
    overlap = Enum.filter(spec.provider_options, &(&1 in spec.normalized_options))

    cond do
      duplicate_normalized != [] -> invalid("normalized option names must be unique")
      duplicate_provider != [] -> invalid("provider option names must be unique")
      overlap != [] -> invalid("provider options cannot shadow normalized options", %{options: overlap})
      true -> :ok
    end
  end

  defp invalid(message, details \\ %{}),
    do: {:error, Jido.Harness.Error.validation(message, details: details)}
end
