defmodule Jido.Harness.Run do
  @moduledoc """
  Supervised lifecycle API for detached provider runs.

  A run survives the process that starts, streams, or awaits it. Keep the
  returned run ID to inspect, reattach to, replay, cancel, or prune the run.

  Events are ordered within the run and exposed through pull-based cursor
  streams or explicit replay pages. An await timeout stops only the waiter; it
  never cancels the run.

  See [Detached runs](detached_runs.html) and
  [Streaming, replay, and retention](streaming_replay_and_retention.html).
  """

  alias Jido.Harness.{Error, Registry, RequestResolver, RunManager, RunRequest, Validation}

  @doc "Starts a detached run using the request provider or configured default."
  @spec start(Jido.Harness.request()) :: Jido.Harness.result(String.t())
  def start(request), do: start_default(request, [])

  @doc """
  Starts a detached run with an explicit provider, or a providerless request
  followed by options.
  """
  @spec start(Jido.Harness.provider() | Jido.Harness.request(), Jido.Harness.request() | keyword()) ::
          Jido.Harness.result(String.t())
  def start(provider, request) when is_atom(provider), do: start(provider, request, [])
  def start(request, options), do: start_default(request, options)

  @doc "Starts a detached run with an explicit provider and options."
  @spec start(Jido.Harness.provider(), Jido.Harness.request(), keyword()) :: Jido.Harness.result(String.t())
  def start(provider, request, options) when is_atom(provider) do
    with {:ok, request} <- prepare_request(provider, request, options) do
      RunManager.start(provider, request)
    end
  end

  def start(provider, _request, _options),
    do: {:error, Error.validation("provider must be an atom", details: %{provider: inspect(provider)})}

  @doc "Returns a redacted snapshot of a run."
  @spec info(String.t()) :: Jido.Harness.result(Jido.Harness.RunInfo.t())
  def info(run_id), do: RunManager.info(run_id)

  @doc "Lists runs, optionally filtering with `providers: [...]` or `states: [...]`."
  @spec list(keyword()) :: [Jido.Harness.RunInfo.t()]
  def list(filters \\ []), do: RunManager.list(filters)

  @doc "Returns a cursor-driven stream that can attach or reattach to a run."
  @spec stream(String.t(), keyword()) :: Jido.Harness.result(term())
  def stream(run_id, options \\ []), do: RunManager.stream(run_id, options)

  @doc "Replays a bounded page of run events after a cursor."
  @spec replay(String.t(), keyword()) :: Jido.Harness.result([Jido.Harness.Event.t()])
  def replay(run_id, options \\ []), do: RunManager.replay(run_id, options)

  @doc "Waits for a run result without cancelling the run when the wait times out."
  @spec await(String.t(), timeout()) :: Jido.Harness.result(Jido.Harness.RunResult.t())
  def await(run_id, timeout \\ :infinity), do: RunManager.await(run_id, timeout)

  @doc "Requests cancellation of a running provider execution."
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(run_id), do: RunManager.cancel(run_id)

  @doc "Removes a terminal run and its retained journal."
  @spec prune(String.t()) :: :ok | {:error, term()}
  def prune(run_id), do: RunManager.prune(run_id)

  defp start_default(%RunRequest{} = request, options) do
    with {:ok, provider} <- request_provider(request.provider, options) do
      start(provider, request, options)
    end
  end

  defp start_default(prompt, options) when is_binary(prompt) do
    with {:ok, provider} <- request_provider(nil, options) do
      start(provider, prompt, options)
    end
  end

  defp start_default(request, options) when is_map(request) or is_list(request) do
    with {:ok, provider} <- request |> provider_value() |> request_provider(options) do
      start(provider, request, options)
    end
  end

  defp start_default(_request, _options),
    do: {:error, Error.validation("request must be a prompt, map, or RunRequest")}

  defp prepare_request(provider, %RunRequest{} = request, []), do: RequestResolver.resolve(provider, request)

  defp prepare_request(provider, %RunRequest{} = request, options) do
    with {:ok, options} <- Validation.options_map(options) do
      request
      |> Map.from_struct()
      |> Map.merge(options)
      |> then(&RequestResolver.resolve(provider, &1))
    end
  end

  defp prepare_request(provider, prompt, options) when is_binary(prompt) do
    with {:ok, options} <- Validation.options_map(options) do
      RequestResolver.resolve(provider, Map.put(options, :prompt, prompt))
    end
  end

  defp prepare_request(provider, request, options) when is_map(request) or is_list(request) do
    with {:ok, request} <- Validation.attributes_map(request, "request"),
         {:ok, options} <- Validation.options_map(options) do
      RequestResolver.resolve(provider, Map.merge(request, options))
    end
  end

  defp prepare_request(_provider, request, _options),
    do: {:error, Error.validation("request must be a prompt, map, or RunRequest", details: %{value: inspect(request)})}

  defp request_provider(request_provider, options) do
    with {:ok, options} <- Validation.options_map(options) do
      provider = provider_value(options) || request_provider || Registry.default_provider()

      case provider do
        provider when is_atom(provider) and not is_nil(provider) -> {:ok, provider}
        nil -> {:error, Error.new(:configuration, "no default provider is configured")}
        value -> {:error, Error.validation("provider must be an atom", details: %{provider: inspect(value)})}
      end
    end
  end

  defp provider_value(values) when is_map(values), do: Map.get(values, :provider) || Map.get(values, "provider")

  defp provider_value(values) when is_list(values) do
    if Keyword.keyword?(values), do: Keyword.get(values, :provider), else: nil
  end
end
