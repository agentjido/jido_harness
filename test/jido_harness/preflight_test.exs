defmodule Jido.Harness.PreflightTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Exec
  alias Jido.Harness.Test.{ExecShellAgentStub, ExecShellState}

  setup do
    ExecShellState.reset!(%{
      tools: %{"git" => true, "gh" => true},
      env: %{}
    })

    :ok
  end

  test "validate_shared_runtime/2 defaults to generic profile only" do
    ExecShellState.reset!(%{
      tools: %{"git" => true, "gh" => false},
      env: %{}
    })

    assert {:ok, checks} =
             Exec.validate_shared_runtime(
               "sess-generic",
               shell_agent_mod: ExecShellAgentStub,
               timeout: 5_000
             )

    assert checks.profiles == [:generic]
    assert checks.generic.tools["git"] == true
    refute Map.has_key?(checks, :github)
  end

  test "validate_shared_runtime/2 runs github profile when requested" do
    ExecShellState.reset!(%{
      tools: %{"git" => true, "gh" => true},
      env: %{"GH_TOKEN" => "token"}
    })

    assert {:ok, checks} =
             Exec.validate_shared_runtime(
               "sess-github",
               shell_agent_mod: ExecShellAgentStub,
               timeout: 5_000,
               profiles: [:generic, :github]
             )

    assert checks.profiles == [:generic, :github]
    assert checks.github.gh == true
    assert checks.github.github_token_visible == true
    assert checks.github.gh_auth == true
    assert checks.gh == true
    assert checks.git == true
  end

  test "validate_shared_runtime/2 reports github-specific failures when github profile is enabled" do
    ExecShellState.reset!(%{
      tools: %{"git" => true, "gh" => false},
      env: %{}
    })

    assert {:error, %Jido.Harness.Error.ExecutionFailureError{details: details}} =
             Exec.validate_shared_runtime(
               "sess-github-fail",
               shell_agent_mod: ExecShellAgentStub,
               timeout: 5_000,
               profile: :github
             )

    assert details[:code] == :shared_runtime_failed
    assert :missing_gh in details[:missing]
    assert :missing_github_token_env in details[:missing]
    assert :missing_github_auth in details[:missing]
  end

  test "validate_shared_runtime/2 supports generic env policies" do
    assert {:error, %Jido.Harness.Error.ExecutionFailureError{details: details}} =
             Exec.validate_shared_runtime(
               "sess-env-any",
               shell_agent_mod: ExecShellAgentStub,
               timeout: 5_000,
               required_env_any: ["FOO", "BAR"]
             )

    missing_env_any_of = Keyword.get(details[:missing], :missing_env_any_of, [])
    assert Enum.sort(missing_env_any_of) == ["BAR", "FOO"]
  end

  test "validate_shared_runtime/2 rejects invalid tool names" do
    assert {:error, %Jido.Harness.Error.InvalidInputError{message: message}} =
             Exec.validate_shared_runtime(
               "sess-invalid-tool",
               shell_agent_mod: ExecShellAgentStub,
               timeout: 5_000,
               required_tools: ["git", "bad tool"]
             )

    assert message =~ "Invalid required tool name"
  end
end
