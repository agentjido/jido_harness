defmodule Jido.Harness.ObserveTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Observe

  test "event helpers build canonical harness namespaces" do
    assert Observe.workspace(:provisioned) == [:jido, :harness, :workspace, :provisioned]
    assert Observe.runtime(:validated) == [:jido, :harness, :runtime, :validated]
    assert Observe.provider(:completed) == [:jido, :harness, :provider, :completed]
  end

  test "ensure_required_metadata/1 fills required keys with nil defaults" do
    metadata = Observe.ensure_required_metadata(%{provider: :claude})

    assert metadata.provider == :claude
    assert Map.has_key?(metadata, :request_id)
    assert Map.has_key?(metadata, :run_id)
    assert Map.has_key?(metadata, :owner)
    assert Map.has_key?(metadata, :repo)
    assert Map.has_key?(metadata, :issue_number)
    assert Map.has_key?(metadata, :session_id)
  end

  test "sanitize_sensitive/1 redacts token-like keys recursively" do
    payload = %{
      token: "secret",
      nested: %{"api_key" => "secret-2", "safe" => "ok"},
      list: [%{auth_token: "secret-3", visible: true}]
    }

    sanitized = Observe.sanitize_sensitive(payload)

    assert sanitized.token == "[REDACTED]"
    assert sanitized.nested["api_key"] == "[REDACTED]"
    assert sanitized.nested["safe"] == "ok"
    assert hd(sanitized.list).auth_token == "[REDACTED]"
  end

  test "emit/3 includes required metadata keys" do
    handler_id = "jido-harness-observe-test-#{System.unique_integer([:positive])}"
    event = Observe.runtime(:validated)
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok = Observe.emit(event, %{duration_ms: 10}, %{provider: :claude, token: "secret"})

    assert_receive {:telemetry_event, %{duration_ms: 10}, metadata}
    assert metadata.provider == :claude
    assert metadata.request_id == nil
    assert metadata.run_id == nil
    assert metadata.token == "[REDACTED]"
  end

  test "start_span/finish_span emits start and stop events" do
    handler_id = "jido-harness-observe-span-test-#{System.unique_integer([:positive])}"
    event_prefix = [:jido, :harness, :runtime, :span_test]
    parent = self()
    start_event = event_prefix ++ [:start]
    stop_event = event_prefix ++ [:stop]

    :ok =
      :telemetry.attach_many(
        handler_id,
        [start_event, stop_event],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_span, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    span = Observe.start_span(event_prefix, %{provider: :claude})
    :ok = Observe.finish_span(span, %{duration_ms: 42})

    assert_receive {:telemetry_span, ^start_event, %{system_time: _}, _metadata}
    assert_receive {:telemetry_span, ^stop_event, %{duration: _, duration_ms: 42}, _metadata}
  end
end
