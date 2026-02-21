defmodule Jido.Harness.RegistryTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Registry
  alias Jido.Harness.Test.{AdapterStub, NoRuntimeContractAdapterStub, OpenCodeRuntimeAdapterStub, RuntimeAdapterStub}

  setup do
    old_providers = Application.get_env(:jido_harness, :providers)
    old_default = Application.get_env(:jido_harness, :default_provider)

    on_exit(fn ->
      restore_env(:jido_harness, :providers, old_providers)
      restore_env(:jido_harness, :default_provider, old_default)
    end)

    :ok
  end

  test "providers/0 only accepts explicitly configured conformant adapters" do
    Application.put_env(:jido_harness, :providers, %{
      :stub => AdapterStub,
      :unsupported => NoRuntimeContractAdapterStub,
      "bad" => AdapterStub
    })

    assert Registry.providers() == %{stub: AdapterStub}
  end

  test "providers/0 rejects configured adapters whose id/0 does not match provider key" do
    Application.put_env(:jido_harness, :providers, %{configured: AdapterStub})

    refute Map.has_key?(Registry.providers(), :configured)

    diagnostics = Registry.diagnostics()
    assert diagnostics.configured.configured.status == :rejected
    assert diagnostics.configured.configured.reason == {:id_mismatch, :stub}
  end

  test "diagnostics/0 reports accepted and rejected configured providers" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub, broken: NoRuntimeContractAdapterStub})

    diagnostics = Registry.diagnostics()

    assert diagnostics.providers.stub == AdapterStub
    assert diagnostics.configured.stub.status == :accepted
    assert diagnostics.configured.broken.status == :rejected
    assert diagnostics.configured.broken.reason == :missing_adapter_behaviour
  end

  test "lookup/1 returns provider not found errors for missing providers" do
    Application.put_env(:jido_harness, :providers, %{})

    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :missing}} = Registry.lookup(:missing)
  end

  test "available?/1 checks configured provider availability" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})

    assert Registry.available?(:stub)
    refute Registry.available?(:unknown)
  end

  test "default_provider/0 prefers configured default when it is available" do
    Application.put_env(:jido_harness, :providers, %{stub: AdapterStub})
    Application.put_env(:jido_harness, :default_provider, :stub)

    assert Registry.default_provider() == :stub
  end

  test "default_provider/0 falls back to first configured provider in sorted order" do
    Application.put_env(:jido_harness, :default_provider, :missing)

    Application.put_env(:jido_harness, :providers, %{
      runtime_stub: RuntimeAdapterStub,
      opencode: OpenCodeRuntimeAdapterStub
    })

    assert Registry.default_provider() == :opencode
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
