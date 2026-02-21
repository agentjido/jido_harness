defmodule Jido.HarnessTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Test.{
    AdapterStub,
    ErrorRunnerStub,
    InvalidEventRunnerStub,
    NoCancelStub,
    NoRuntimeContractAdapterStub
  }

  setup do
    old_providers = Application.get_env(:jido_harness, :providers)
    old_default = Application.get_env(:jido_harness, :default_provider)

    on_exit(fn ->
      restore_env(:jido_harness, :providers, old_providers)
      restore_env(:jido_harness, :default_provider, old_default)
    end)

    :ok
  end

  test "run/3 returns error for unavailable provider" do
    Application.put_env(:jido_harness, :providers, %{})

    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :nonexistent}} =
             Jido.Harness.run(:nonexistent, "hello")
  end

  test "run/2 returns validation error when no default provider is configured" do
    Application.put_env(:jido_harness, :providers, %{})
    Application.delete_env(:jido_harness, :default_provider)

    assert {:error, %Jido.Harness.Error.InvalidInputError{field: :default_provider}} =
             Jido.Harness.run("hello", [])
  end

  test "run/3 delegates to configured adapter modules" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})
    request_opts = [cwd: "/tmp/project"]
    runtime_opts = [transport: :exec]

    assert {:ok, stream} = Jido.Harness.run(:stub, "hello", request_opts ++ runtime_opts)
    events = Enum.to_list(stream)

    assert_receive {:adapter_stub_run, request, [transport: :exec]}
    assert request.prompt == "hello"
    assert request.cwd == "/tmp/project"
    assert [%Jido.Harness.Event{type: :session_started}] = events
  end

  test "run/2 uses configured default provider" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})
    Application.put_env(:jido_harness, :default_provider, :stub)

    assert {:ok, stream} = Jido.Harness.run("hello", [])
    assert [%Jido.Harness.Event{type: :session_started}] = Enum.to_list(stream)
  end

  test "run_request/3 delegates to adapter run/2 with RunRequest input" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})
    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:ok, stream} = Jido.Harness.run_request(:stub, request, turn: 1)
    events = Enum.to_list(stream)

    assert_receive {:adapter_stub_run, ^request, [turn: 1]}
    assert [%Jido.Harness.Event{type: :session_started}] = events
  end

  test "run_request/3 returns provider-not-found for non-adapter modules" do
    Application.put_env(:jido_harness, :providers, %{unsupported: NoRuntimeContractAdapterStub})
    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :unsupported}} =
             Jido.Harness.run_request(:unsupported, request, [])
  end

  test "run_request/2 returns validation error when no default provider is configured" do
    Application.put_env(:jido_harness, :providers, %{})
    Application.delete_env(:jido_harness, :default_provider)
    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:error, %Jido.Harness.Error.InvalidInputError{field: :default_provider}} =
             Jido.Harness.run_request(request, [])
  end

  test "capabilities/1 delegates to adapter capabilities when present" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})

    assert {:ok, capabilities} = Jido.Harness.capabilities(:stub)
    assert capabilities.tool_calls? == true
    assert capabilities.cancellation? == true
  end

  test "capabilities/1 returns provider-not-found for non-adapter modules" do
    Application.put_env(:jido_harness, :providers, %{unsupported: NoRuntimeContractAdapterStub})

    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :unsupported}} =
             Jido.Harness.capabilities(:unsupported)
  end

  test "cancel/2 delegates to provider cancel when supported" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})

    assert :ok = Jido.Harness.cancel(:stub, "session-1")
    assert_receive {:adapter_stub_cancel, "session-1"}
  end

  test "cancel/2 returns structured error when unsupported" do
    Application.put_env(:jido_harness, :providers, %{no_cancel: NoCancelStub})

    assert {:error, %Jido.Harness.Error.ExecutionFailureError{}} = Jido.Harness.cancel(:no_cancel, "session-1")
  end

  test "cancel/2 validates invalid session ids" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})
    assert {:error, %Jido.Harness.Error.InvalidInputError{}} = Jido.Harness.cancel(:stub, "")
  end

  test "capabilities/1 returns provider-not-found for missing providers" do
    Application.put_env(:jido_harness, :providers, %{})
    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :missing}} = Jido.Harness.capabilities(:missing)
  end

  test "providers/0 returns provider metadata list" do
    Application.put_env(:jido_harness, :providers, %{
      stub: AdapterStub
    })

    providers = Jido.Harness.providers()
    assert Enum.any?(providers, &(&1.id == :stub))
  end

  test "default_provider/0 delegates to registry default provider" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})
    Application.put_env(:jido_harness, :default_provider, :stub)
    assert Jido.Harness.default_provider() == :stub
  end

  test "run/3 passes through provider error tuples" do
    Application.put_env(:jido_harness, :providers, %{error_runner: ErrorRunnerStub})
    assert {:error, :boom} = Jido.Harness.run(:error_runner, "hello")
  end

  test "run/3 enforces stream entries are normalized events" do
    Application.put_env(:jido_harness, :providers, %{invalid_events: InvalidEventRunnerStub})

    assert {:ok, stream} = Jido.Harness.run(:invalid_events, "hello")
    assert_receive {:invalid_event_runner_run, "hello", _opts}

    assert_raise ArgumentError, fn ->
      Enum.to_list(stream)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
