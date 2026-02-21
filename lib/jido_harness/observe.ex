defmodule Jido.Harness.Observe do
  @moduledoc """
  Harness observability boundary for canonical telemetry events and spans.
  """

  alias Jido.Observe, as: CoreObserve

  @required_metadata_keys [
    :request_id,
    :run_id,
    :provider,
    :owner,
    :repo,
    :issue_number,
    :session_id
  ]

  @sensitive_exact_keys MapSet.new([
                          "api_key",
                          "apikey",
                          "password",
                          "secret",
                          "token",
                          "auth_token",
                          "authtoken",
                          "private_key",
                          "privatekey",
                          "access_key",
                          "accesskey",
                          "bearer",
                          "api_secret",
                          "apisecret",
                          "client_secret",
                          "clientsecret"
                        ])

  @sensitive_contains ["secret_"]
  @sensitive_suffixes ["_secret", "_key", "_token", "_password"]

  @type event_name :: [atom()]
  @type metadata :: map()
  @type measurements :: map()
  @type span_ctx :: CoreObserve.span_ctx() | :noop

  @doc "Builds a canonical workspace telemetry event path."
  @spec workspace(atom()) :: event_name()
  def workspace(event), do: [:jido, :harness, :workspace, event]

  @doc "Builds a canonical runtime telemetry event path."
  @spec runtime(atom()) :: event_name()
  def runtime(event), do: [:jido, :harness, :runtime, event]

  @doc "Builds a canonical provider telemetry event path."
  @spec provider(atom()) :: event_name()
  def provider(event), do: [:jido, :harness, :provider, event]

  @doc "Emits a harness telemetry event with required metadata defaults."
  @spec emit(event_name(), measurements(), metadata()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    CoreObserve.emit_event(
      event,
      measurements,
      metadata
      |> ensure_required_metadata()
      |> sanitize_sensitive()
    )
  end

  @doc "Starts a harness telemetry span."
  @spec start_span(event_name(), metadata()) :: span_ctx()
  def start_span(event_prefix, metadata \\ %{}) when is_list(event_prefix) and is_map(metadata) do
    CoreObserve.start_span(event_prefix, ensure_required_metadata(metadata))
  end

  @doc "Finishes a harness telemetry span."
  @spec finish_span(span_ctx(), measurements()) :: :ok
  def finish_span(span_ctx, measurements \\ %{})
  def finish_span(:noop, _measurements), do: :ok
  def finish_span(span_ctx, measurements) when is_map(measurements), do: CoreObserve.finish_span(span_ctx, measurements)

  @doc "Finishes a harness span with exception metadata."
  @spec finish_span_error(span_ctx(), atom(), term(), list()) :: :ok
  def finish_span_error(:noop, _kind, _reason, _stacktrace), do: :ok

  def finish_span_error(span_ctx, kind, reason, stacktrace),
    do: CoreObserve.finish_span_error(span_ctx, kind, reason, stacktrace)

  @doc "Ensures required metadata keys are present."
  @spec ensure_required_metadata(metadata()) :: metadata()
  def ensure_required_metadata(metadata) when is_map(metadata) do
    Enum.reduce(@required_metadata_keys, metadata, fn key, acc ->
      Map.put_new(acc, key, nil)
    end)
  end

  @doc "Recursively redacts sensitive telemetry payload keys."
  @spec sanitize_sensitive(term()) :: term()
  def sanitize_sensitive(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_sensitive(value)}
      end
    end)
  end

  def sanitize_sensitive(payload) when is_list(payload), do: Enum.map(payload, &sanitize_sensitive/1)
  def sanitize_sensitive(payload), do: payload

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()

  defp sensitive_key?(key) when is_binary(key) do
    key = String.downcase(key)

    MapSet.member?(@sensitive_exact_keys, key) or
      Enum.any?(@sensitive_contains, &String.contains?(key, &1)) or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(key, &1))
  end

  defp sensitive_key?(_key), do: false
end
