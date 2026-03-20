defmodule Jido.Harness.RuntimeFacadeTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.RunRequest
  alias Jido.Harness.Test.{RuntimeBackedAdapterStub, RuntimeDriverStub}

  setup do
    old_providers = Application.get_env(:jido_harness, :providers)
    old_default_provider = Application.get_env(:jido_harness, :default_provider)
    old_runtime_drivers = Application.get_env(:jido_harness, :runtime_drivers)
    old_default_runtime_driver = Application.get_env(:jido_harness, :default_runtime_driver)

    on_exit(fn ->
      restore_env(:jido_harness, :providers, old_providers)
      restore_env(:jido_harness, :default_provider, old_default_provider)
      restore_env(:jido_harness, :runtime_drivers, old_runtime_drivers)
      restore_env(:jido_harness, :default_runtime_driver, old_default_runtime_driver)
    end)

    :ok
  end

  test "driver-first facade routes pure runtime drivers without adapter behaviour" do
    Application.put_env(:jido_harness, :runtime_drivers, %{stub_runtime: RuntimeDriverStub})
    Application.put_env(:jido_harness, :default_runtime_driver, :stub_runtime)

    request =
      RunRequest.new!(%{
        prompt: "hello through runtime",
        cwd: "/tmp/runtime-project",
        metadata: %{}
      })

    assert {:ok, session} =
             Jido.Harness.start_session(
               provider: :stub_runtime,
               session_id: "runtime-session-1",
               cwd: "/tmp/runtime-project"
             )

    refute Map.has_key?(Map.from_struct(session), :driver_ref)

    assert {:ok, run, stream} = Jido.Harness.stream_run(session, request, run_id: "runtime-run-1")
    assert {:ok, status} = Jido.Harness.session_status(session)
    assert {:ok, result} = Jido.Harness.run_result(session, request, run_id: "runtime-run-2")
    assert :ok = Jido.Harness.approve(session, "approval-1", :allow, source: "runtime-facade-test")
    assert {:ok, cost} = Jido.Harness.cost(session)
    assert :ok = Jido.Harness.cancel_run(session, run)
    assert :ok = Jido.Harness.stop_session(session)

    events = Enum.to_list(stream)

    assert_receive {:runtime_driver_stub_start_session, start_opts}
    assert start_opts[:cwd] == "/tmp/runtime-project"
    assert start_opts[:provider] == :stub_runtime

    assert_receive {:runtime_driver_stub_stream_run, "runtime-session-1", ^request, [run_id: "runtime-run-1"]}
    assert_receive {:runtime_driver_stub_run, "runtime-session-1", ^request, [run_id: "runtime-run-2"]}

    assert_receive {:runtime_driver_stub_approve, "runtime-session-1", "approval-1", :allow,
                    [source: "runtime-facade-test"]}

    assert_receive {:runtime_driver_stub_cost, "runtime-session-1"}
    assert_receive {:runtime_driver_stub_cancel_run, "runtime-session-1", "runtime-run-1"}
    assert_receive {:runtime_driver_stub_stop_session, "runtime-session-1"}

    assert status.state == :ready
    assert result.run_id == "runtime-run-2"
    assert cost["cost_usd"] == 0.01

    assert [%Jido.Harness.ExecutionEvent{type: :run_started}, %Jido.Harness.ExecutionEvent{type: :result}] =
             events
  end

  test "legacy run_request/3 keeps runtime-backed adapters working through provider config" do
    Application.put_env(:jido_harness, :providers, %{runtime_adapter: RuntimeBackedAdapterStub})

    request =
      RunRequest.new!(%{
        prompt: "hello through runtime",
        cwd: "/tmp/runtime-project",
        metadata: %{}
      })

    assert {:ok, stream} = Jido.Harness.run_request(:runtime_adapter, request, transport: :exec)
    events = Enum.to_list(stream)

    assert_receive {:runtime_backed_adapter_start_session, start_opts}
    assert start_opts[:cwd] == "/tmp/runtime-project"
    assert start_opts[:transport] == :exec

    assert_receive {:runtime_backed_adapter_stream_run, "runtime-session-1", ^request, [transport: :exec]}
    refute_receive {:runtime_backed_adapter_legacy_run, _, _}
    assert_receive {:runtime_backed_adapter_stop_session, "runtime-session-1"}

    assert [%Jido.Harness.Event{type: :run_started}, %Jido.Harness.Event{type: :result}] = events
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
