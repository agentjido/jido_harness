defmodule Jido.Harness.Signal do
  @moduledoc "Native Signal helpers for normalized Harness activity."

  alias Jido.Harness.Adapter.Message
  alias Jido.Harness.Process.DriverMessage

  @definitions %{
    run_started: Jido.Harness.Signal.Run.Started,
    run_completed: Jido.Harness.Signal.Run.Completed,
    run_failed: Jido.Harness.Signal.Run.Failed,
    run_cancelled: Jido.Harness.Signal.Run.Cancelled,
    session_started: Jido.Harness.Signal.Session.Started,
    session_ready: Jido.Harness.Signal.Session.Ready,
    session_idle: Jido.Harness.Signal.Session.Idle,
    session_closed: Jido.Harness.Signal.Session.Closed,
    session_failed: Jido.Harness.Signal.Session.Failed,
    session_cancelled: Jido.Harness.Signal.Session.Cancelled,
    input_accepted: Jido.Harness.Signal.Input.Accepted,
    turn_queued: Jido.Harness.Signal.Turn.Queued,
    turn_started: Jido.Harness.Signal.Turn.Started,
    turn_completed: Jido.Harness.Signal.Turn.Completed,
    turn_failed: Jido.Harness.Signal.Turn.Failed,
    turn_interrupted: Jido.Harness.Signal.Turn.Interrupted,
    output_text_delta: Jido.Harness.Signal.Output.TextDelta,
    output_text_final: Jido.Harness.Signal.Output.TextFinal,
    structured_output: Jido.Harness.Signal.Output.Structured,
    thinking_delta: Jido.Harness.Signal.Thinking.Delta,
    command_output_delta: Jido.Harness.Signal.ProviderCommand.OutputDelta,
    tool_call: Jido.Harness.Signal.Tool.Call,
    tool_result: Jido.Harness.Signal.Tool.Result,
    file_change: Jido.Harness.Signal.File.Changed,
    plan_updated: Jido.Harness.Signal.Plan.Updated,
    usage: Jido.Harness.Signal.Usage.Reported,
    approval_requested: Jido.Harness.Signal.Approval.Requested,
    approval_resolved: Jido.Harness.Signal.Approval.Resolved,
    queue_changed: Jido.Harness.Signal.Queue.Changed,
    provider_message: Jido.Harness.Signal.Provider.Message,
    replay_gap: Jido.Harness.Signal.Replay.Gap,
    process_started: Jido.Harness.Signal.Process.Started,
    process_stdout: Jido.Harness.Signal.Process.Stdout,
    process_stderr: Jido.Harness.Signal.Process.Stderr,
    process_exited: Jido.Harness.Signal.Process.Exited,
    process_failed: Jido.Harness.Signal.Process.Failed,
    process_cancelled: Jido.Harness.Signal.Process.Cancelled,
    process_timed_out: Jido.Harness.Signal.Process.TimedOut
  }

  @command_definitions [
    Jido.Harness.Signal.Command.Run.Start,
    Jido.Harness.Signal.Command.Run.Cancel,
    Jido.Harness.Signal.Command.Run.Prune,
    Jido.Harness.Signal.Command.Session.Start,
    Jido.Harness.Signal.Command.Session.SendMessage,
    Jido.Harness.Signal.Command.Session.FollowUp,
    Jido.Harness.Signal.Command.Session.Steer,
    Jido.Harness.Signal.Command.Session.Interrupt,
    Jido.Harness.Signal.Command.Session.RespondApproval,
    Jido.Harness.Signal.Command.Session.Configure,
    Jido.Harness.Signal.Command.Session.Close,
    Jido.Harness.Signal.Command.Session.Kill,
    Jido.Harness.Signal.Command.Session.Prune,
    Jido.Harness.Signal.Command.Accepted,
    Jido.Harness.Signal.Command.Failed
  ]

  @types Map.new(@definitions, fn {kind, module} -> {module.type(), kind} end)
  @run_terminal_types ~w(jido.harness.run.completed jido.harness.run.failed jido.harness.run.cancelled)
  @session_terminal_types ~w(jido.harness.session.closed jido.harness.session.failed jido.harness.session.cancelled)
  @turn_terminal_types ~w(jido.harness.turn.completed jido.harness.turn.failed jido.harness.turn.interrupted)

  @doc "Returns all Harness fact and command Signal definitions."
  @spec definitions() :: [module()]
  def definitions, do: Map.values(@definitions) ++ @command_definitions

  @doc "Returns all Harness command Signal definitions."
  @spec command_definitions() :: [module()]
  def command_definitions, do: @command_definitions

  @doc "Returns a catalog that contains every Harness Signal definition."
  @spec catalog() :: Jido.Signal.Catalog.t()
  def catalog, do: Jido.Signal.Catalog.new!(definitions())

  @doc "Returns the normalized Harness kind for a fact Signal, or `nil` for a command Signal."
  @spec kind(Jido.Signal.t()) :: atom() | nil
  def kind(%Jido.Signal{type: type}), do: Map.get(@types, type)

  @doc "Returns a fact Signal's resource-local sequence."
  @spec sequence(Jido.Signal.t()) :: pos_integer()
  def sequence(%Jido.Signal{data: %{"sequence" => sequence}}), do: sequence

  @doc "Returns whether a Signal or type is a terminal run fact."
  @spec run_terminal?(Jido.Signal.t() | String.t()) :: boolean()
  def run_terminal?(%Jido.Signal{type: type}), do: run_terminal?(type)
  def run_terminal?(type) when is_binary(type), do: type in @run_terminal_types
  def run_terminal?(_value), do: false

  @doc "Returns whether a Signal or type is a terminal session fact."
  @spec session_terminal?(Jido.Signal.t() | String.t()) :: boolean()
  def session_terminal?(%Jido.Signal{type: type}), do: session_terminal?(type)
  def session_terminal?(type) when is_binary(type), do: type in @session_terminal_types
  def session_terminal?(_value), do: false

  @doc "Returns whether a Signal or type is a terminal turn fact."
  @spec turn_terminal?(Jido.Signal.t() | String.t()) :: boolean()
  def turn_terminal?(%Jido.Signal{type: type}), do: turn_terminal?(type)
  def turn_terminal?(type) when is_binary(type), do: type in @turn_terminal_types
  def turn_terminal?(_value), do: false

  @doc "Returns whether a Signal or type is a terminal run or session fact."
  @spec terminal?(Jido.Signal.t() | String.t()) :: boolean()
  def terminal?(signal_or_type),
    do: run_terminal?(signal_or_type) or session_terminal?(signal_or_type)

  @doc false
  @spec from_adapter(Message.t(), :run | :session, String.t(), atom(), pos_integer(), map()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def from_adapter(%Message{} = message, resource, id, provider, sequence, metadata \\ %{}) do
    attrs = %{
      resource_id_key(resource) => id,
      "provider" => Atom.to_string(provider),
      "provider_session_id" => message.provider_session_id,
      "turn_id" => message.turn_id,
      "request_id" => message.request_id,
      "sequence" => sequence,
      "payload" => message.payload,
      "metadata" => stringify(metadata)
    }

    build(message.type, attrs, source(resource, id), message.timestamp, subject(message.turn_id))
  end

  @doc false
  @spec from_process(DriverMessage.t(), String.t(), pos_integer()) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def from_process(%DriverMessage{} = message, process_id, sequence) do
    kind = String.to_existing_atom("process_#{message.type}")

    attrs = %{
      "process_id" => process_id,
      "sequence" => sequence,
      "payload" => process_payload(message),
      "metadata" => stringify(message.metadata)
    }

    build(kind, attrs, source(:process, process_id), message.timestamp, nil)
  end

  @doc "Builds a replay-gap Signal for a missing resource sequence range."
  @spec replay_gap(:run | :session | :process, String.t(), map(), map()) :: Jido.Signal.t()
  def replay_gap(resource, id, gap, metadata \\ %{}) do
    attrs = %{
      resource_id_key(resource) => id,
      "sequence" => gap.to,
      "payload" => %{
        "from" => gap.from,
        "to" => gap.to,
        "reason" => Atom.to_string(gap.reason)
      },
      "metadata" => stringify(metadata)
    }

    {:ok, signal} = build(:replay_gap, attrs, source(resource, id), DateTime.utc_now() |> DateTime.to_iso8601(), nil)
    signal
  end

  @doc false
  @spec build(atom(), map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Jido.Signal.t()} | {:error, term()}
  def build(kind, attrs, source, time, subject) do
    module = Map.fetch!(@definitions, kind)
    attrs = attrs |> stringify() |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
    options = [source: source, time: time] ++ if(subject, do: [subject: subject], else: [])
    module.new(attrs, options)
  end

  defp resource_id_key(:run), do: "run_id"
  defp resource_id_key(:session), do: "session_id"
  defp resource_id_key(:process), do: "process_id"

  defp source(resource, id),
    do: "urn:jido:harness:#{resource}:" <> Base.url_encode64(id, padding: false)

  defp subject(nil), do: nil
  defp subject(turn_id), do: "turn:" <> Base.url_encode64(turn_id, padding: false)

  defp process_payload(message) do
    %{
      "stream" => message.stream && Atom.to_string(message.stream),
      "data" => encode_binary(message.data)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_binary(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"encoding" => "base64", "data" => Base.encode64(value)}
  end

  defp encode_binary(value), do: stringify(value)

  defp stringify(%_{} = value), do: value |> Map.from_struct() |> stringify()
  defp stringify(value) when is_map(value), do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
