defmodule Jido.Harness.Amp.Status do
  @moduledoc "Readiness and environment defaults for the Amp Orb control surface."

  @schema Zoi.struct(
            __MODULE__,
            %{
              installed: Zoi.boolean(),
              authenticated: Zoi.boolean(),
              ready: Zoi.boolean(),
              executable: Zoi.string() |> Zoi.nullish(),
              service_url: Zoi.string(),
              project: Zoi.string() |> Zoi.nullish(),
              orb_size: Zoi.string() |> Zoi.nullish(),
              orb_provider: Zoi.string() |> Zoi.nullish(),
              profile: Zoi.string() |> Zoi.nullish(),
              mode: Zoi.string() |> Zoi.nullish(),
              visibility: Zoi.enum([:private, :unlisted, :workspace, :group]) |> Zoi.nullish(),
              features: Zoi.array(Zoi.string()) |> Zoi.default([]),
              labels: Zoi.array(Zoi.string()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Amp Orb control readiness."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates and constructs Amp Orb control readiness."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    case Zoi.parse(@schema, Map.new(attrs)) do
      {:ok, status} ->
        {:ok, status}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid Amp status", details: %{reason: inspect(reason)})}
    end
  end
end
