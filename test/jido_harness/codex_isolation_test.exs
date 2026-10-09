defmodule Jido.Harness.CodexIsolationTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Error, SessionRequest}
  alias Jido.Harness.Adapters.Codex.Isolation

  test "explicit false controls do not require adapter support" do
    request = request(%{ephemeral: false, ignore_user_config: false})

    assert :ok = Isolation.validate(request)

    assert {:ok, %{"CODEX_EPHEMERAL" => "0", "CODEX_IGNORE_USER_CONFIG" => "0"}} =
             Isolation.environment(request)

    assert :ok = Isolation.validate_capabilities(request, %{})
  end

  test "each isolation control can be enabled independently" do
    for {option, variable, capability} <- [
          {:ephemeral, "CODEX_EPHEMERAL", "ephemeral"},
          {:ignore_user_config, "CODEX_IGNORE_USER_CONFIG", "ignoreUserConfig"}
        ] do
      request = request(%{option => true})
      assert {:ok, %{^variable => "1"} = environment} = Isolation.environment(request)
      assert map_size(environment) == 1

      assert :ok =
               Isolation.validate_capabilities(request, %{
                 "_meta" => %{"codex" => %{"isolation" => %{capability => true}}}
               })

      assert {:error, %Error{category: :configuration, details: %{option: ^option}}} =
               Isolation.validate_capabilities(request, %{})
    end
  end

  test "present non-boolean values are rejected for atom and string keys" do
    for option <- [:ephemeral, :ignore_user_config],
        key <- [option, Atom.to_string(option)],
        value <- [:absent, nil, "true", 1] do
      request = request(%{key => value})

      for result <- [
            Isolation.validate(request),
            Isolation.environment(request),
            Isolation.validate_capabilities(request, %{})
          ] do
        assert {:error, %Error{category: :validation, details: %{option: ^option}}} = result
      end
    end
  end

  test "duplicate atom and string controls are rejected" do
    for option <- [:ephemeral, :ignore_user_config] do
      request = request(%{option => true, Atom.to_string(option) => false})

      assert {:error, %Error{category: :validation, message: "duplicate Codex isolation option"}} =
               Isolation.validate(request)
    end
  end

  defp request(options) do
    {:ok, request} = SessionRequest.new(%{provider_options: options})
    request
  end
end
