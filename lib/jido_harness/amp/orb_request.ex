defmodule Jido.Harness.Amp.OrbRequest do
  @moduledoc "Validated input for a new Amp Orb thread."

  @keys [
    :prompt,
    :project,
    :orb_size,
    :orb_provider,
    :profile,
    :title,
    :mode,
    :visibility,
    :features,
    :labels,
    :attachments
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              prompt: Zoi.string(),
              project: Zoi.string() |> Zoi.nullish(),
              orb_size: Zoi.string() |> Zoi.nullish(),
              orb_provider: Zoi.string() |> Zoi.nullish(),
              profile: Zoi.string() |> Zoi.nullish(),
              title: Zoi.string() |> Zoi.nullish(),
              mode: Zoi.string() |> Zoi.nullish(),
              visibility: Zoi.enum([:private, :unlisted, :workspace, :group]) |> Zoi.nullish(),
              features: Zoi.array(Zoi.string()) |> Zoi.default([]),
              labels: Zoi.array(Zoi.string()) |> Zoi.default([]),
              attachments: Zoi.array(Zoi.string()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @key_strings Map.new(@keys, &{Atom.to_string(&1), &1})
  @visibility_strings %{
    "private" => :private,
    "unlisted" => :unlisted,
    "workspace" => :workspace,
    "group" => :group
  }

  @doc "Returns the Zoi schema for an Amp Orb request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Validates a new Amp Orb request."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_keys(attrs),
         {:ok, attrs} <- normalize_visibility(attrs),
         :ok <- validate_values(attrs),
         {:ok, request} <- parse(attrs) do
      {:ok, request}
    end
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: new(Map.new(attrs)),
      else: {:error, Jido.Harness.Error.validation("Amp Orb request must be a map or keyword list")}
  end

  def new(other) do
    {:error,
     Jido.Harness.Error.validation("Amp Orb request must be a map or keyword list", details: %{value: inspect(other)})}
  end

  @doc "Validates an Amp Orb request, or raises an error."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, error} -> raise error
    end
  end

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

  defp normalize_visibility(%{visibility: value} = attrs) when is_binary(value) do
    case Map.fetch(@visibility_strings, value) do
      {:ok, visibility} -> {:ok, %{attrs | visibility: visibility}}
      :error -> {:error, Jido.Harness.Error.validation("invalid Amp thread visibility", details: %{visibility: value})}
    end
  end

  defp normalize_visibility(attrs), do: {:ok, attrs}

  defp validate_values(attrs) do
    string_fields = [:prompt, :project, :orb_size, :orb_provider, :profile, :title, :mode]
    list_fields = [:features, :labels, :attachments]

    cond do
      field = Enum.find(string_fields, &invalid_string?(Map.get(attrs, &1), &1 == :prompt)) ->
        {:error, Jido.Harness.Error.validation("#{field} must be a non-empty string")}

      field = Enum.find(list_fields, &invalid_string_list?(Map.get(attrs, &1, []))) ->
        {:error, Jido.Harness.Error.validation("#{field} must contain non-empty strings")}

      true ->
        :ok
    end
  end

  defp invalid_string?(nil, false), do: false
  defp invalid_string?(value, _required?), do: not (is_binary(value) and String.trim(value) != "")

  defp invalid_string_list?(values),
    do: not (is_list(values) and Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")))

  defp parse(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid Amp Orb request", details: %{reason: inspect(reason)})}
    end
  end

  defp unknown_key(key),
    do: {:error, Jido.Harness.Error.validation("unknown Amp Orb request option", details: %{key: key})}
end
