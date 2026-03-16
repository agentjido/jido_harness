defmodule Jido.Harness.RuntimeRegistryTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.RuntimeRegistry
  alias Jido.Harness.Test.RuntimeDriverStub

  setup do
    old_runtime_drivers = Application.get_env(:jido_harness, :runtime_drivers)
    old_default = Application.get_env(:jido_harness, :default_runtime_driver)

    on_exit(fn ->
      restore_env(:jido_harness, :runtime_drivers, old_runtime_drivers)
      restore_env(:jido_harness, :default_runtime_driver, old_default)
    end)

    :ok
  end

  test "runtime_drivers/0 accepts pure runtime drivers without adapter behaviour" do
    Application.put_env(:jido_harness, :runtime_drivers, %{stub_runtime: RuntimeDriverStub})

    assert RuntimeRegistry.runtime_drivers() == %{stub_runtime: RuntimeDriverStub}
  end

  test "runtime_drivers/0 rejects configured drivers whose runtime_id/0 does not match the configured key" do
    Application.put_env(:jido_harness, :runtime_drivers, %{configured: RuntimeDriverStub})

    refute Map.has_key?(RuntimeRegistry.runtime_drivers(), :configured)

    diagnostics = RuntimeRegistry.diagnostics()
    assert diagnostics.configured.configured.status == :rejected
    assert diagnostics.configured.configured.reason == {:runtime_id_mismatch, :stub_runtime}
  end

  test "diagnostics/0 reports accepted and rejected configured runtime drivers" do
    Application.put_env(:jido_harness, :runtime_drivers, %{
      stub_runtime: RuntimeDriverStub,
      broken: Jido.Harness.Test.AdapterStub
    })

    diagnostics = RuntimeRegistry.diagnostics()

    assert diagnostics.runtime_drivers.stub_runtime == RuntimeDriverStub
    assert diagnostics.configured.stub_runtime.status == :accepted
    assert diagnostics.configured.broken.status == :rejected

    assert diagnostics.configured.broken.reason ==
             {:missing_callbacks,
              [
                runtime_id: 0,
                runtime_descriptor: 1,
                start_session: 1,
                stop_session: 1,
                stream_run: 3,
                cancel_run: 2,
                session_status: 1
              ]}
  end

  test "lookup/1 returns runtime-driver not found errors for missing runtime drivers" do
    Application.put_env(:jido_harness, :runtime_drivers, %{})

    assert {:error, %Jido.Harness.Error.RuntimeDriverNotFoundError{runtime_id: :missing}} =
             RuntimeRegistry.lookup(:missing)
  end

  test "available?/1 checks configured runtime-driver availability" do
    Application.put_env(:jido_harness, :runtime_drivers, %{stub_runtime: RuntimeDriverStub})

    assert RuntimeRegistry.available?(:stub_runtime)
    refute RuntimeRegistry.available?(:unknown)
  end

  test "default_runtime_driver/0 prefers configured default when it is available" do
    Application.put_env(:jido_harness, :runtime_drivers, %{stub_runtime: RuntimeDriverStub})
    Application.put_env(:jido_harness, :default_runtime_driver, :stub_runtime)

    assert RuntimeRegistry.default_runtime_driver() == :stub_runtime
  end

  test "default_runtime_driver/0 falls back to first configured runtime driver in sorted order" do
    Application.put_env(:jido_harness, :default_runtime_driver, :missing)

    Application.put_env(:jido_harness, :runtime_drivers, %{
      stub_runtime: RuntimeDriverStub,
      alpha_runtime: Jido.Harness.Test.AlphaRuntimeDriverStub
    })

    assert RuntimeRegistry.default_runtime_driver() == :alpha_runtime
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
