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

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    provider_config = Application.get_env(:jido_harness, :provider_config)

    Application.put_env(:jido_harness, :providers, %{environment_capture: CaptureAdapter})
    Application.put_env(:jido_harness, :provider_config, %{environment_capture: %{}})

    on_exit(fn ->
      restore(:providers, providers)
      restore(:provider_config, provider_config)
      Jido.Harness.TestHelpers.cleanup_sessions()
      Jido.Harness.TestHelpers.cleanup_runs()
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
