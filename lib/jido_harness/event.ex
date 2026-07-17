defmodule Jido.Harness.Event do
  @moduledoc "A sequenced provider-neutral event emitted by a harness run."

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
    :provider_event
  ]
  @run_terminal_types [:run_completed, :run_failed, :run_cancelled]
  @session_terminal_types [:session_closed, :session_failed, :session_cancelled]
  @turn_terminal_types [:turn_completed, :turn_failed, :turn_interrupted]
  @terminal_types @run_terminal_types ++ @session_terminal_types

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Zoi.enum(@types),
              run_id: Zoi.string() |> Zoi.nullish(),
              session_id: Zoi.string() |> Zoi.nullish(),
              provider: Zoi.atom(),
              provider_session_id: Zoi.string() |> Zoi.nullish(),
              turn_id: Zoi.string() |> Zoi.nullish(),
              request_id: Zoi.string() |> Zoi.nullish(),
              sequence: Zoi.integer() |> Zoi.default(0),
              timestamp: Zoi.string(),
              payload: Zoi.map(Zoi.string(), Zoi.any()) |> Zoi.default(%{}),
              raw: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type event_type :: unquote(Enum.reduce(@types, &{:|, [], [&1, &2]}))
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec types() :: [event_type()]
  @doc "Returns every canonical event type."
  def types, do: @types

  @spec terminal?(t() | event_type()) :: boolean()
  @doc "Returns whether an event or event type terminates a run."
  def terminal?(%__MODULE__{type: type}), do: terminal?(type)
  def terminal?(type), do: type in @terminal_types

  @doc "Returns whether an event terminates a finite run."
  def run_terminal?(%__MODULE__{type: type}), do: run_terminal?(type)
  def run_terminal?(type), do: type in @run_terminal_types

  @doc "Returns whether an event terminates an interactive session."
  def session_terminal?(%__MODULE__{type: type}), do: session_terminal?(type)
  def session_terminal?(type), do: type in @session_terminal_types

  @doc "Returns whether an event terminates a turn while leaving its session available."
  def turn_terminal?(%__MODULE__{type: type}), do: turn_terminal?(type)
  def turn_terminal?(type), do: type in @turn_terminal_types

  @spec schema() :: Zoi.schema()
  @doc "Returns the Zoi schema used to validate canonical events."
  def schema, do: @schema

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Jido.Harness.Error.t()}
  @doc "Validates and constructs a canonical event."
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
      |> update_payload()

    case Zoi.parse(@schema, attrs) do
      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        {:error, Jido.Harness.Error.validation("invalid harness event", details: %{reason: inspect(reason)})}
    end
  end

  @spec new!(map() | keyword()) :: t()
  @doc "Validates and constructs an event, raising on invalid input."
  def new!(attrs) do
    case new(attrs) do
      {:ok, event} -> event
      {:error, error} -> raise error
    end
  end

  @spec attach(t(), String.t(), atom(), pos_integer()) :: t()
  @doc "Attaches stable run identity and sequence information to an adapter event."
  def attach(%__MODULE__{} = event, run_id, provider, sequence) do
    %{event | run_id: run_id, session_id: nil, provider: provider, sequence: sequence}
  end

  @spec attach_session(t(), String.t(), atom(), pos_integer()) :: t()
  @doc "Attaches harness session identity and sequence information to an event."
  def attach_session(%__MODULE__{} = event, session_id, provider, sequence) do
    %{event | run_id: nil, session_id: session_id, provider: provider, sequence: sequence}
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
