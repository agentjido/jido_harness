defmodule Jido.Harness.Session do
  @moduledoc """
  Supervised lifecycle API for interactive provider sessions.

  Sessions own multi-turn conversation state independently of their callers.
  The harness session ID is distinct from a provider's resume token.

  Session transports declare whether multi-turn behavior, interruption,
  steering, approvals, multimodal input, and configuration are native, managed,
  process-backed, or unsupported. Unsupported interactions fail before provider
  dispatch.

  See [Interactive sessions](interactive_sessions.html) and
  [Providers and capabilities](providers.html).
  """

  alias Jido.Harness.{Error, Registry, SessionManager, SessionRequest, TurnRequest, Validation}

  @type request :: map() | keyword() | SessionRequest.t()
  @type turn_input :: String.t() | map() | keyword() | TurnRequest.t()

  @doc "Starts a caller-independent interactive provider session."
  @spec start(Jido.Harness.provider(), request(), keyword()) :: Jido.Harness.result(String.t())
  def start(provider, request \\ %{}, options \\ [])

  def start(provider, request, options) when is_atom(provider) do
    with {:ok, request} <- prepare_request(provider, request, options) do
      SessionManager.start(provider, request)
    end
  end

  def start(provider, _request, _options),
    do: {:error, Error.validation("provider must be an atom", details: %{provider: inspect(provider)})}

  @doc "Returns a redacted snapshot of a session."
  @spec info(String.t()) :: Jido.Harness.result(Jido.Harness.SessionInfo.t())
  def info(session_id), do: SessionManager.info(session_id)

  @doc "Lists sessions, optionally filtering with `providers: [...]` or `states: [...]`."
  @spec list(keyword()) :: [Jido.Harness.SessionInfo.t()]
  def list(filters \\ []), do: SessionManager.list(filters)

  @doc "Returns a cursor-driven stream that can attach or reattach to a session."
  @spec stream(String.t(), keyword()) :: Jido.Harness.result(term())
  def stream(session_id, options \\ []), do: SessionManager.stream(session_id, options)

  @doc "Replays a bounded page of session events after a cursor."
  @spec replay(String.t(), keyword()) :: Jido.Harness.result([Jido.Harness.Event.t()])
  def replay(session_id, options \\ []), do: SessionManager.replay(session_id, options)

  @doc "Starts a turn when the session is idle and returns its stable turn ID."
  @spec send_message(String.t(), turn_input(), keyword()) :: Jido.Harness.result(String.t())
  def send_message(session_id, input, options \\ []) do
    with {:ok, request} <- prepare_turn(input, options) do
      SessionManager.send_message(session_id, request)
    end
  end

  @doc "Queues a follow-up turn and returns its stable turn ID."
  @spec follow_up(String.t(), turn_input(), keyword()) :: Jido.Harness.result(String.t())
  def follow_up(session_id, input, options \\ []) do
    with {:ok, request} <- prepare_turn(input, options) do
      SessionManager.follow_up(session_id, request)
    end
  end

  @doc "Steers the active turn when the selected transport supports it."
  @spec steer(String.t(), turn_input(), keyword()) :: Jido.Harness.result(String.t())
  def steer(session_id, input, options \\ []) do
    with {:ok, request} <- prepare_turn(input, options) do
      SessionManager.steer(session_id, request)
    end
  end

  @doc "Waits for one turn without interrupting it when the wait times out."
  @spec await(String.t(), String.t(), timeout()) :: Jido.Harness.result(Jido.Harness.TurnResult.t())
  def await(session_id, turn_id, timeout \\ :infinity), do: SessionManager.await_turn(session_id, turn_id, timeout)

  @doc "Interrupts the active turn while keeping its session available."
  @spec interrupt(String.t(), String.t() | :active) :: :ok | {:error, term()}
  def interrupt(session_id, turn_id \\ :active), do: SessionManager.interrupt(session_id, turn_id)

  @doc "Responds to a pending normalized provider approval request."
  @spec respond_approval(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def respond_approval(session_id, request_id, response),
    do: SessionManager.respond_approval(session_id, request_id, response)

  @doc "Changes supported runtime session configuration."
  @spec configure(String.t(), map()) :: :ok | {:error, term()}
  def configure(session_id, changes), do: SessionManager.configure(session_id, changes)

  @doc "Gracefully closes a session."
  @spec close(String.t()) :: :ok | {:error, term()}
  def close(session_id), do: SessionManager.close(session_id)

  @doc "Forcibly cancels a session."
  @spec kill(String.t()) :: :ok | {:error, term()}
  def kill(session_id), do: SessionManager.kill(session_id)

  @doc "Removes a terminal session and its retained journal."
  @spec prune(String.t()) :: :ok | {:error, term()}
  def prune(session_id), do: SessionManager.prune(session_id)

  defp prepare_request(provider, %SessionRequest{} = request, options) do
    with {:ok, options} <- Validation.options_map(options) do
      request
      |> Map.from_struct()
      |> Map.merge(options)
      |> Map.put(:provider, provider)
      |> SessionRequest.new()
    end
  end

  defp prepare_request(provider, request, options) when is_map(request) or is_list(request) do
    with {:ok, request} <- Validation.attributes_map(request, "session request"),
         {:ok, options} <- Validation.options_map(options) do
      provider
      |> Registry.provider_config()
      |> Map.get(:session_defaults, %{})
      |> Map.new()
      |> Map.merge(request)
      |> Map.merge(options)
      |> Map.put(:provider, provider)
      |> SessionRequest.new()
    end
  end

  defp prepare_request(_provider, request, _options),
    do: {:error, Error.validation("session request must be a map", details: %{value: inspect(request)})}

  defp prepare_turn(%TurnRequest{} = request, []), do: {:ok, request}

  defp prepare_turn(%TurnRequest{} = request, options) do
    with {:ok, options} <- Validation.options_map(options) do
      request |> Map.from_struct() |> Map.merge(options) |> TurnRequest.new()
    end
  end

  defp prepare_turn(input, []), do: TurnRequest.new(input)

  defp prepare_turn(input, options) when is_binary(input) do
    with {:ok, options} <- Validation.options_map(options) do
      options |> Map.put(:prompt, input) |> TurnRequest.new()
    end
  end

  defp prepare_turn(input, options) when is_map(input) or is_list(input) do
    with {:ok, input} <- Validation.attributes_map(input, "turn request"),
         {:ok, options} <- Validation.options_map(options) do
      input |> Map.merge(options) |> TurnRequest.new()
    end
  end

  defp prepare_turn(input, _options),
    do: {:error, Error.validation("turn request must be text or a map", details: %{value: inspect(input)})}
end
