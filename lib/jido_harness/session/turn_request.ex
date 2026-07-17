defmodule Jido.Harness.TurnRequest do
  @moduledoc "Validated input for one turn in an interactive session."

  @reasoning_efforts [:low, :medium, :high]
  @keys [:prompt, :content, :attachments, :reasoning_effort, :output_schema, :metadata, :provider_options]

  @schema Zoi.struct(
            __MODULE__,
            %{
              prompt: Zoi.string() |> Zoi.nullish(),
              content: Zoi.array(Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any())) |> Zoi.default([]),
              attachments: Zoi.array(Zoi.string()) |> Zoi.default([]),
              reasoning_effort: Zoi.enum(@reasoning_efforts) |> Zoi.nullish(),
              output_schema: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.nullish(),
              metadata: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{}),
              provider_options: Zoi.map(Zoi.union([Zoi.string(), Zoi.atom()]), Zoi.any()) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @key_strings Map.new(@keys, &{Atom.to_string(&1), &1})

  @doc "Returns the validation schema for turn requests."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates text or structured content for one interactive turn."
  @spec new(t() | String.t() | map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(%__MODULE__{} = request), do: {:ok, request}
  def new(prompt) when is_binary(prompt), do: new(%{prompt: prompt})

  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_keys(attrs),
         :ok <- validate_input(attrs),
         {:ok, request} <- parse(attrs) do
      {:ok, request}
    end
  end

  def new(attrs) when is_list(attrs) do
    if Enum.all?(attrs, &match?({_, _}, &1)),
      do: new(Map.new(attrs)),
      else: {:error, Jido.Harness.Error.validation("turn request must be text or a map")}
  end

  def new(other),
    do: {:error, Jido.Harness.Error.validation("turn request must be text or a map", details: %{value: inspect(other)})}

  @doc "Validates a turn request and raises on invalid input."
  @spec new!(t() | String.t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, error} -> raise error
    end
  end

  @doc "Extracts the plain-text representation of a turn request."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{prompt: prompt}) when is_binary(prompt), do: prompt

  def text(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, :type) in [:text, "text"]))
    |> Enum.map(&(Map.get(&1, :text) || Map.get(&1, "text") || ""))
    |> Enum.join("\n")
  end

  defp validate_input(attrs) do
    prompt = Map.get(attrs, :prompt)
    content = Map.get(attrs, :content, [])
    provider_options = Map.get(attrs, :provider_options, %{})

    cond do
      not is_map(provider_options) ->
        {:error, Jido.Harness.Error.validation("provider_options must be a map")}

      shadow = Enum.find(Map.keys(provider_options), &shadows_normalized?/1) ->
        {:error,
         Jido.Harness.Error.validation("provider_options cannot shadow normalized fields", details: %{key: shadow})}

      is_binary(prompt) and String.trim(prompt) != "" and content == [] ->
        :ok

      is_nil(prompt) and is_list(content) and content != [] ->
        :ok

      true ->
        {:error, Jido.Harness.Error.validation("turn requires either a non-empty prompt or content blocks")}
    end
  end

  defp shadows_normalized?(key) when is_atom(key), do: key in @keys
  defp shadows_normalized?(key) when is_binary(key), do: Map.has_key?(@key_strings, key)
  defp shadows_normalized?(_key), do: false

  defp normalize_keys(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when key in @keys ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        case Map.fetch(@key_strings, key) do
          {:ok, atom} -> {:cont, {:ok, Map.put(acc, atom, value)}}
          :error -> {:halt, unknown_key(key)}
        end

      {key, _value}, _acc ->
        {:halt, unknown_key(key)}
    end)
  end

  defp parse(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid turn request", details: %{reason: inspect(reason)})}
    end
  end

  defp unknown_key(key),
    do: {:error, Jido.Harness.Error.validation("unknown turn request option", details: %{key: key})}
end
