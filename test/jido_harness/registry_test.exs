defmodule Jido.Harness.RegistryTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Registry
  alias Jido.Harness.Test.{AdapterStub, PromptRunnerStub}

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

  test "providers/0 merges discovered and configured providers" do
    Application.put_env(:jido_harness, :provider_candidates, %{auto: [AdapterStub], missing: [Missing.Module]})
    Application.put_env(:jido_harness, :providers, %{:configured => AdapterStub, "bad" => AdapterStub})

    providers = Registry.providers()

    assert providers.auto == AdapterStub
    assert providers.configured == AdapterStub
    refute Map.has_key?(providers, :missing)
    refute Map.has_key?(providers, "bad")
  end

  test "providers/0 ignores invalid discovery candidates" do
    Application.put_env(:jido_harness, :provider_candidates, %{invalid: [123, nil, Missing.Module]})
    Application.put_env(:jido_harness, :providers, %{})

    refute Map.has_key?(Registry.providers(), :invalid)
  end

  test "providers/0 rejects configured providers that are not adapter modules" do
    Application.put_env(:jido_harness, :provider_candidates, %{})
    Application.put_env(:jido_harness, :providers, %{prompt: PromptRunnerStub})

    refute Map.has_key?(Registry.providers(), :prompt)
  end

  test "diagnostics/0 reports rejected discovery and configured candidates" do
    Application.put_env(:jido_harness, :provider_candidates, %{prompt: [PromptRunnerStub], auto: [AdapterStub]})
    Application.put_env(:jido_harness, :providers, %{configured: AdapterStub, bad_configured: PromptRunnerStub})

    diagnostics = Registry.diagnostics()

    assert diagnostics.providers.auto == AdapterStub
    assert diagnostics.providers.configured == AdapterStub
    assert diagnostics.discovered.prompt |> hd() |> Map.fetch!(:status) == :rejected
    assert diagnostics.configured.bad_configured.status == :rejected
  end

  test "lookup/1 returns provider not found errors for missing providers" do
    Application.put_env(:jido_harness, :provider_candidates, %{})
    Application.put_env(:jido_harness, :providers, %{})

    assert {:error, %Jido.Harness.Error.ProviderNotFoundError{provider: :missing}} = Registry.lookup(:missing)
  end

  test "available?/1 checks provider availability" do
    Application.put_env(:jido_harness, :providers, %{configured: AdapterStub})
    assert Registry.available?(:configured)
    refute Registry.available?(:unknown)
  end

  test "default_provider/0 prefers configured default when available" do
    Application.put_env(:jido_harness, :providers, %{configured: AdapterStub})
    Application.put_env(:jido_harness, :default_provider, :configured)

    assert Registry.default_provider() == :configured
  end

  test "default_provider/0 falls back to discovered candidate order" do
    Application.put_env(:jido_harness, :default_provider, :missing)
    Application.put_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :provider_candidates, %{codex: [AdapterStub], amp: [AdapterStub]})

    assert Registry.default_provider() in [:codex, :amp]
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
