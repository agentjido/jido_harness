defmodule Jido.Harness.RegistryTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{AdapterSpec, Error, Registry, RequestResolver}

  test "registers all eight built-in harnesses and no shell provider" do
    providers = Registry.providers()

    assert Map.keys(providers) |> Enum.sort() == [:amp, :claude, :codex, :gemini, :grok, :kimi, :opencode, :zai]
    refute Map.has_key?(providers, :shell)

    for provider <- Map.keys(providers) do
      assert {:ok, %AdapterSpec{provider: ^provider}} = Registry.spec(provider)
    end
  end

  test "providerless requests require an explicit default provider" do
    original = Application.get_env(:jido_harness, :default_provider)
    Application.delete_env(:jido_harness, :default_provider)
    on_exit(fn -> if original, do: Application.put_env(:jido_harness, :default_provider, original) end)

    assert {:error, %Error{category: :configuration}} =
             Jido.Harness.start_request(%{prompt: "hello"})
  end

  test "request precedence is adapter defaults, application defaults, then explicit values" do
    original = Application.get_env(:jido_harness, :provider_config)

    Application.put_env(:jido_harness, :provider_config, %{
      codex: %{request_defaults: %{model: "application-model", sandbox_mode: :read_only}}
    })

    on_exit(fn ->
      if original,
        do: Application.put_env(:jido_harness, :provider_config, original),
        else: Application.delete_env(:jido_harness, :provider_config)
    end)

    assert {:ok, request} =
             RequestResolver.resolve(:codex, %{
               prompt: "hello",
               model: "explicit-model"
             })

    assert request.model == "explicit-model"
    assert request.sandbox_mode == :read_only
  end
end
