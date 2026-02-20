defmodule Jido.Harness.ProviderRuntimeHardeningTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Exec

  alias Jido.Harness.Test.{
    ExecShellAgentStub,
    ExecShellState,
    InvalidEnvRuntimeAdapterStub,
    RuntimeAdapterStub
  }

  setup do
    old_providers = Application.get_env(:jido_harness, :providers)
    old_candidates = Application.get_env(:jido_harness, :provider_candidates)

    on_exit(fn ->
      restore_env(:jido_harness, :providers, old_providers)
      restore_env(:jido_harness, :provider_candidates, old_candidates)
    end)

    ExecShellState.reset!(%{
      tools: %{"gh" => true, "git" => true, "runtime-tool" => false},
      env: %{}
    })

    :ok
  end

  test "bootstrap_provider_runtime revalidates provider requirements after bootstrap" do
    Application.put_env(:jido_harness, :providers, %{runtime_stub: RuntimeAdapterStub})
    Application.put_env(:jido_harness, :provider_candidates, %{})

    assert {:ok, result} =
             Exec.bootstrap_provider_runtime(
               :runtime_stub,
               "sess-runtime",
               shell_agent_mod: ExecShellAgentStub,
               timeout: 5_000
             )

    assert result.post_validation.tools["runtime-tool"] == true
    assert result.post_validation.env.required_all["RUNTIME_KEY"] == true

    commands = ExecShellState.runs()
    assert Enum.any?(commands, &String.contains?(&1, "install-runtime-tool"))
    assert Enum.any?(commands, &String.contains?(&1, "bootstrap-runtime-auth"))
  end

  test "validate_provider_runtime rejects invalid env var names from runtime contract" do
    Application.put_env(:jido_harness, :providers, %{runtime_invalid_env: InvalidEnvRuntimeAdapterStub})
    Application.put_env(:jido_harness, :provider_candidates, %{})

    assert {:error, %Jido.Harness.Error.InvalidInputError{message: message}} =
             Exec.validate_provider_runtime(
               :runtime_invalid_env,
               "sess-runtime",
               shell_agent_mod: ExecShellAgentStub,
               timeout: 5_000
             )

    assert message =~ "Invalid env var name"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
