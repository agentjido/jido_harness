defmodule Jido.HarnessTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Test.{
    AdapterStub,
    AtomMapStreamRunnerStub,
    ErrorRunnerStub,
    ExecuteRunnerStub,
    InvalidEventRunnerStub,
    NoCancelStub,
    PromptRunnerStub,
    RunRequestRunnerStub,
    StreamRunnerStub,
    UnsupportedRunnerStub
  }

  setup do
    old_providers = Application.get_env(:jido_harness, :providers)
    old_default = Application.get_env(:jido_harness, :default_provider)
    old_candidates = Application.get_env(:jido_harness, :provider_candidates)

    on_exit(fn ->
      restore_env(:jido_harness, :providers, old_providers)
      restore_env(:jido_harness, :default_provider, old_default)
      restore_env(:jido_harness, :provider_candidates, old_candidates)
    end)

    :ok
  end

  test "run/3 returns error for unavailable provider" do
    Application.put_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :provider_candidates, %{})

    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :nonexistent}} =
             Jido.Harness.run(:nonexistent, "hello")
  end

  test "run/2 returns a validation error when no default provider exists" do
    Application.put_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :provider_candidates, %{})
    Application.delete_env(:jido_harness, :default_provider)

    assert {:error, %Jido.Harness.Error.InvalidInputError{field: :default_provider}} = Jido.Harness.run("hello", [])
  end

  test "run/3 delegates to adapter-style modules" do
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

  test "run/2 uses default provider" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})
    Application.put_env(:jido_harness, :default_provider, :stub)

    assert {:ok, stream} = Jido.Harness.run("hello", [])
    assert [%Jido.Harness.Event{type: :session_started}] = Enum.to_list(stream)
  end

  test "run/3 falls back to prompt-runner modules" do
    Application.put_env(:jido_harness, :providers, %{prompt: PromptRunnerStub})

    assert {:ok, stream} = Jido.Harness.run(:prompt, "hello", cwd: "/tmp")
    events = Enum.to_list(stream)

    assert_receive {:prompt_runner_run, "hello", opts}
    assert opts[:cwd] == "/tmp"
    assert [%Jido.Harness.Event{type: :output_text_final, provider: :prompt}] = events
    assert hd(events).payload["text"] =~ "done: hello"
  end

  test "run/3 normalizes raw stream events from prompt-runner modules" do
    Application.put_env(:jido_harness, :providers, %{stream: StreamRunnerStub})

    assert {:ok, stream} = Jido.Harness.run(:stream, "hello")
    events = Enum.to_list(stream)

    assert_receive {:stream_runner_run, "hello", _opts}
    assert Enum.map(events, & &1.type) == [:output_text_delta, :session_completed]
    assert Enum.all?(events, &(&1.provider == :stream))
  end

  test "run/3 normalizes atom-key map events" do
    Application.put_env(:jido_harness, :providers, %{atom_stream: AtomMapStreamRunnerStub})

    assert {:ok, stream} = Jido.Harness.run(:atom_stream, "hello")
    events = Enum.to_list(stream)

    assert_receive {:atom_map_stream_runner_run, "hello", _opts}
    assert [%Jido.Harness.Event{type: :session_completed, provider: :atom_stream}] = events
  end

  test "run_request/3 delegates to run_request modules" do
    Application.put_env(:jido_harness, :providers, %{rq: RunRequestRunnerStub})
    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:ok, stream} = Jido.Harness.run_request(:rq, request, turn: 1)
    events = Enum.to_list(stream)

    assert_receive {:run_request_runner_run, ^request, [turn: 1]}
    assert [%Jido.Harness.Event{type: :session_completed, provider: :run_request_stub}] = events
  end

  test "run_request/3 uses execute/2 fallback when available" do
    Application.put_env(:jido_harness, :providers, %{exec: ExecuteRunnerStub})
    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", cwd: "/tmp", metadata: %{}})

    assert {:ok, stream} = Jido.Harness.run_request(:exec, request, retry: true)
    events = Enum.to_list(stream)

    assert_receive {:execute_runner_execute, "hello", opts}
    assert opts[:cwd] == "/tmp"
    assert opts[:retry] == true
    assert [%Jido.Harness.Event{type: :provider_event, provider: :exec}] = events
  end

  test "run_request/3 returns execution error for unsupported modules" do
    Application.put_env(:jido_harness, :providers, %{unsupported: UnsupportedRunnerStub})
    request = Jido.Harness.RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:error, %Jido.Harness.Error.ExecutionFailureError{}} = Jido.Harness.run_request(:unsupported, request, [])
  end

  test "run_request/2 returns a validation error when no default provider exists" do
    Application.put_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :provider_candidates, %{})
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

  test "capabilities/1 infers defaults for non-adapter modules" do
    Application.put_env(:jido_harness, :providers, %{prompt: PromptRunnerStub})

    assert {:ok, capabilities} = Jido.Harness.capabilities(:prompt)
    assert capabilities.streaming? == true
    assert capabilities.cancellation? == false
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
    Application.put_env(:jido_harness, :provider_candidates, %{})

    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :missing}} = Jido.Harness.capabilities(:missing)
  end

  test "providers/0 returns provider metadata list" do
    Application.put_env(:jido_harness, :providers, %{
      stub: AdapterStub,
      codex: AdapterStub,
      amp: AdapterStub,
      claude: AdapterStub,
      gemini: AdapterStub
    })

    providers = Jido.Harness.providers()
    assert Enum.any?(providers, &(&1.id == :stub))
    assert Enum.any?(providers, &(&1.id == :codex and &1.docs_url == "https://hex.pm/packages/jido_codex"))
    assert Enum.any?(providers, &(&1.id == :amp and &1.docs_url == "https://hex.pm/packages/jido_amp"))
    assert Enum.any?(providers, &(&1.id == :claude and &1.docs_url == "https://hex.pm/packages/jido_claude"))
    assert Enum.any?(providers, &(&1.id == :gemini and &1.docs_url == "https://hex.pm/packages/jido_gemini"))
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

  test "run/3 falls back when provider emits invalid event shapes" do
    Application.put_env(:jido_harness, :providers, %{invalid_events: InvalidEventRunnerStub})
    assert {:ok, stream} = Jido.Harness.run(:invalid_events, "hello")
    events = Enum.to_list(stream)

    assert_receive {:invalid_event_runner_run, "hello", _opts}
    assert Enum.all?(events, &(&1.type == :provider_event))
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
