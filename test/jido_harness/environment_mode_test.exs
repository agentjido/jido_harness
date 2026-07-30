defmodule Jido.Harness.EnvironmentModeTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{AdapterSpec, Capabilities, Event, RunRequest}
  alias Jido.Harness.Adapters.CLIStream

  defmodule CaptureProcessManager do
    def start_owned_process(spec, owner) do
      send(owner, {:process_spec, spec})
      {:ok, "proc_test"}
    end

    def stream_process("proc_test"), do: {:ok, []}
  end

  defmodule CaptureAdapter do
    @behaviour Jido.Harness.Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :environment_capture,
        name: "Environment capture",
        executable: "fixture",
        capabilities: %Capabilities{streaming?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config), do: Jido.Harness.TestAdapter.status(%{})

    @impl true
    def run(request, _context) do
      send(request.metadata.test_pid, {:run_request, request})
      {:ok, [Event.new!(provider: :environment_capture, type: :turn_completed, payload: %{})]}
    end
  end

  defmodule CaptureProcessDriver do
    @behaviour Jido.Harness.ProcessDriver

    @impl true
    def start(spec, _owner) do
      test_pid = Application.fetch_env!(:jido_harness, :environment_mode_test_pid)
      os_pid = System.unique_integer([:positive])

      exec_pid =
        spawn_link(fn ->
          receive do
            :finish -> :ok
          end
        end)

      send(test_pid, {:process_spec, spec})
      send(exec_pid, :finish)
      {:ok, exec_pid, os_pid}
    end

    @impl true
    def send_input(_process, _data), do: :ok

    @impl true
    def signal(_process, _signal), do: :ok
  end

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    provider_config = Application.get_env(:jido_harness, :provider_config)
    process_driver = Application.get_env(:jido_harness, :process_driver)
    test_pid = Application.get_env(:jido_harness, :environment_mode_test_pid)

    Application.put_env(:jido_harness, :providers, %{environment_capture: CaptureAdapter})
    Application.put_env(:jido_harness, :provider_config, %{environment_capture: %{}})
    Application.put_env(:jido_harness, :process_driver, CaptureProcessDriver)
    Application.put_env(:jido_harness, :environment_mode_test_pid, self())

    on_exit(fn ->
      restore(:providers, providers)
      restore(:provider_config, provider_config)
      restore(:process_driver, process_driver)
      restore(:environment_mode_test_pid, test_pid)
      Jido.Harness.TestHelpers.cleanup_sessions()
      Jido.Harness.TestHelpers.cleanup_runs()
      Jido.Harness.TestHelpers.cleanup_processes()
    end)

    :ok
  end

  test "finite-run CLI process specifications preserve replacement mode" do
    request =
      RunRequest.new!(%{
        prompt: "test",
        env: %{"RUN_SCOPE" => "scoped"},
        env_mode: :replace
      })

    context = %{
      run_id: "run_test",
      run_owner: self(),
      process_manager: CaptureProcessManager
    }

    assert {:ok, stream} =
             CLIStream.run(
               :environment_capture,
               request,
               context,
               "/bin/true",
               [],
               fn _event -> [] end
             )

    assert Enum.to_list(stream) == []
    assert_receive {:process_spec, %{env_mode: :replace, env: %{"RUN_SCOPE" => "scoped"}}}
  end

  test "managed sessions preserve replacement mode for every finite turn" do
    assert {:ok, session_id} =
             Jido.Harness.Session.start(:environment_capture, %{
               env: %{"RUN_SCOPE" => "scoped"},
               env_mode: :replace,
               metadata: %{test_pid: self()}
             })

    assert eventually(fn ->
             match?({:ok, %{state: :idle}}, Jido.Harness.Session.info(session_id))
           end)

    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "test")
    assert_receive {:run_request, %RunRequest{env_mode: :replace, env: %{"RUN_SCOPE" => "scoped"}}}
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session_id, turn_id, 5_000)
  end

  test "finite Z.AI and Kimi runs do not import ambient credentials in replacement mode" do
    put_ambient_credentials()

    zai_overlay = capture_run_spec(:zai, %{prompt: "test", env_mode: :overlay})
    assert zai_overlay.env["ANTHROPIC_AUTH_TOKEN"] == "ambient-zai"

    kimi_overlay = capture_run_spec(:kimi, %{prompt: "test", env_mode: :overlay})
    assert kimi_overlay.env["KIMI_MODEL_NAME"] == "ambient-kimi-model"
    assert kimi_overlay.env["KIMI_MODEL_API_KEY"] == "ambient-kimi-key"

    zai_replace = capture_run_spec(:zai, %{prompt: "test", env_mode: :replace})
    refute Map.has_key?(zai_replace.env, "ANTHROPIC_AUTH_TOKEN")

    kimi_replace = capture_run_spec(:kimi, %{prompt: "test", env_mode: :replace})
    refute Map.has_key?(kimi_replace.env, "KIMI_MODEL_NAME")
    refute Map.has_key?(kimi_replace.env, "KIMI_MODEL_API_KEY")

    zai_request =
      capture_run_spec(:zai, %{
        prompt: "test",
        env_mode: :replace,
        env: %{"ZAI_API_KEY" => "request-zai"}
      })

    assert zai_request.env["ANTHROPIC_AUTH_TOKEN"] == "request-zai"

    kimi_request =
      capture_run_spec(:kimi, %{
        prompt: "test",
        model: "request-kimi-model",
        env_mode: :replace,
        env: %{"KIMI_MODEL_API_KEY" => "request-kimi-key"}
      })

    assert kimi_request.env["KIMI_MODEL_NAME"] == "request-kimi-model"
    assert kimi_request.env["KIMI_MODEL_API_KEY"] == "request-kimi-key"

    Application.put_env(:jido_harness, :provider_config, %{
      zai: %{env: %{"ZAI_API_KEY" => "configured-zai"}},
      kimi: %{
        env: %{
          "KIMI_MODEL_NAME" => "configured-kimi-model",
          "KIMI_MODEL_API_KEY" => "configured-kimi-key"
        }
      }
    })

    zai_config = capture_run_spec(:zai, %{prompt: "test", env_mode: :replace})
    assert zai_config.env["ANTHROPIC_AUTH_TOKEN"] == "configured-zai"

    kimi_config = capture_run_spec(:kimi, %{prompt: "test", env_mode: :replace})
    assert kimi_config.env["KIMI_MODEL_NAME"] == "configured-kimi-model"
    assert kimi_config.env["KIMI_MODEL_API_KEY"] == "configured-kimi-key"
  end

  test "managed Z.AI and Kimi sessions apply the same replacement credential rules" do
    put_ambient_credentials()

    zai_overlay = capture_managed_turn_spec(:zai, %{env_mode: :overlay})
    assert zai_overlay.env["ANTHROPIC_AUTH_TOKEN"] == "ambient-zai"

    kimi_overlay = capture_managed_turn_spec(:kimi, %{env_mode: :overlay})
    assert kimi_overlay.env["KIMI_MODEL_NAME"] == "ambient-kimi-model"
    assert kimi_overlay.env["KIMI_MODEL_API_KEY"] == "ambient-kimi-key"

    zai_replace = capture_managed_turn_spec(:zai, %{env_mode: :replace})
    refute Map.has_key?(zai_replace.env, "ANTHROPIC_AUTH_TOKEN")

    kimi_replace = capture_managed_turn_spec(:kimi, %{env_mode: :replace})
    refute Map.has_key?(kimi_replace.env, "KIMI_MODEL_NAME")
    refute Map.has_key?(kimi_replace.env, "KIMI_MODEL_API_KEY")

    zai_request =
      capture_managed_turn_spec(:zai, %{
        env_mode: :replace,
        env: %{"ZAI_API_KEY" => "session-zai"}
      })

    assert zai_request.env["ANTHROPIC_AUTH_TOKEN"] == "session-zai"

    kimi_request =
      capture_managed_turn_spec(:kimi, %{
        model: "session-kimi-model",
        env_mode: :replace,
        env: %{"KIMI_MODEL_API_KEY" => "session-kimi-key"}
      })

    assert kimi_request.env["KIMI_MODEL_NAME"] == "session-kimi-model"
    assert kimi_request.env["KIMI_MODEL_API_KEY"] == "session-kimi-key"
  end

  defp capture_run_spec(provider, request) do
    assert {:ok, run_id} = Jido.Harness.Run.start(provider, request)
    assert_receive {:process_spec, spec}, 1_000
    assert {:ok, %{status: :completed}} = Jido.Harness.Run.await(run_id, 5_000)
    spec
  end

  defp capture_managed_turn_spec(provider, request) do
    request = if provider == :kimi, do: Map.put(request, :transport, :managed), else: request
    assert {:ok, session_id} = Jido.Harness.Session.start(provider, request)
    assert eventually(fn -> match?({:ok, %{state: :idle}}, Jido.Harness.Session.info(session_id)) end)
    assert {:ok, turn_id} = Jido.Harness.Session.send_message(session_id, "test")
    assert_receive {:process_spec, spec}, 1_000
    assert {:ok, %{status: :completed}} = Jido.Harness.Session.await(session_id, turn_id, 5_000)
    assert :ok = Jido.Harness.Session.close(session_id)
    spec
  end

  defp put_ambient_credentials do
    put_env("ZAI_API_KEY", "ambient-zai")
    put_env("KIMI_MODEL_NAME", "ambient-kimi-model")
    put_env("KIMI_MODEL_API_KEY", "ambient-kimi-key")
  end

  defp put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(_function, 0), do: false

  defp eventually(function, attempts) do
    if function.() do
      true
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
