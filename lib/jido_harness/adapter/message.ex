defmodule Jido.Harness.Adapter.Message do
  @moduledoc false

  @types [
    :run_started,
    :run_completed,
    :run_failed,
    :run_cancelled,
    :session_started,
    :session_ready,
    :session_idle,
    :session_closed,
    :session_failed,
    :session_cancelled,
    :input_accepted,
    :turn_queued,
    :turn_started,
    :output_text_delta,
    :output_text_final,
    :structured_output,
    :thinking_delta,
    :command_output_delta,
    :tool_call,
    :tool_result,
    :file_change,
    :plan_updated,
    :usage,
    :turn_completed,
    :turn_failed,
    :turn_interrupted,
    :approval_requested,
    :approval_resolved,
    :queue_changed,
    :provider_message
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Zoi.enum(@types),
              provider_session_id: Zoi.string() |> Zoi.nullish(),
              turn_id: Zoi.string() |> Zoi.nullish(),
              request_id: Zoi.string() |> Zoi.nullish(),
              timestamp: Zoi.string(),
              payload: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              raw: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type type :: unquote(Enum.reduce(@types, &{:|, [], [&1, &2]}))
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
      |> update_payload()

    case Zoi.parse(@schema, attrs) do
      {:ok, message} ->
        {:ok, message}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid adapter message", details: %{reason: inspect(reason)})}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, message} -> message
      {:error, error} -> raise error
    end
  end

  defp update_payload(attrs) do
    case Map.fetch(attrs, :payload) do
      {:ok, payload} -> Map.put(attrs, :payload, stringify_keys(payload))
      :error -> attrs
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
