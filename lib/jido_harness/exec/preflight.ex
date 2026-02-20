defmodule Jido.Harness.Exec.Preflight do
  @moduledoc """
  Shared runtime checks required by all providers.
  """

  alias Jido.Harness.Exec.Error
  alias Jido.Shell.Exec

  @spec validate_shared_runtime(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_shared_runtime(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    shell_agent_mod = Keyword.get(opts, :shell_agent_mod, Jido.Shell.Agent)
    timeout = Keyword.get(opts, :timeout, 30_000)

    gh = tool_present?(shell_agent_mod, session_id, "gh", timeout)
    git = tool_present?(shell_agent_mod, session_id, "git", timeout)
    github_token_visible = token_visible?(shell_agent_mod, session_id, timeout)
    {gh_auth, gh_login} = github_auth_ok?(shell_agent_mod, session_id, timeout)

    checks = %{
      gh: gh,
      git: git,
      github_token_visible: github_token_visible,
      gh_auth: gh_auth,
      gh_login: gh_login
    }

    case missing_shared_requirements(checks) do
      [] ->
        {:ok, checks}

      missing ->
        {:error,
         Error.execution("Shared runtime requirements failed", %{
           code: :shared_runtime_failed,
           missing: missing,
           checks: checks
         })}
    end
  end

  defp tool_present?(shell_agent_mod, session_id, tool, timeout) do
    cmd = "command -v #{tool} >/dev/null 2>&1 && echo present || echo missing"

    case Exec.run(shell_agent_mod, session_id, cmd, timeout: timeout) do
      {:ok, "present"} -> true
      _ -> false
    end
  end

  defp token_visible?(shell_agent_mod, session_id, timeout) do
    cmd = "if [ -n \"${GH_TOKEN:-}\" ] || [ -n \"${GITHUB_TOKEN:-}\" ]; then echo present; else echo missing; fi"

    case Exec.run(shell_agent_mod, session_id, cmd, timeout: timeout) do
      {:ok, "present"} -> true
      _ -> false
    end
  end

  defp github_auth_ok?(shell_agent_mod, session_id, timeout) do
    auth_cmd = "gh auth status -h github.com >/dev/null 2>&1 || gh auth status >/dev/null 2>&1"

    case Exec.run(shell_agent_mod, session_id, auth_cmd, timeout: timeout) do
      {:ok, _} ->
        {true, nil}

      {:error, _} ->
        case Exec.run(shell_agent_mod, session_id, "gh api user --jq .login", timeout: timeout) do
          {:ok, login} when is_binary(login) and login != "" -> {true, login}
          _ -> {false, nil}
        end
    end
  end

  defp missing_shared_requirements(checks) do
    []
    |> maybe_add_missing(checks.gh, :missing_gh)
    |> maybe_add_missing(checks.git, :missing_git)
    |> maybe_add_missing(checks.github_token_visible, :missing_github_token_env)
    |> maybe_add_missing(checks.gh_auth, :missing_github_auth)
  end

  defp maybe_add_missing(acc, true, _reason), do: acc
  defp maybe_add_missing(acc, false, reason), do: acc ++ [reason]
end
