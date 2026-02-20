defmodule Jido.Harness.Exec.Preflight do
  @moduledoc """
  Shared runtime checks for shell-backed execution.

  Profiles:
  - `:generic` (default): tool/env visibility checks, provider-agnostic.
  - `:github` (optional): GitHub CLI token/auth checks for GitHub workflows.
  """

  alias Jido.Harness.Exec.Error
  alias Jido.Shell.Exec

  @env_var_name_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @tool_name_regex ~r/^[A-Za-z0-9._+-]+$/
  @default_profiles [:generic]
  @supported_profiles [:generic, :github]
  @default_required_tools ["git"]
  @default_github_token_env_any ["GH_TOKEN", "GITHUB_TOKEN"]

  @doc """
  Validates shared runtime prerequisites in a shell session.

  Supports profile composition via `:profile`/`:profiles`:
  - `:generic` (default): required tools and env visibility checks.
  - `:github`: adds `gh` token/auth checks.
  """
  @spec validate_shared_runtime(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_shared_runtime(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    shell_agent_mod = Keyword.get(opts, :shell_agent_mod, Jido.Shell.Agent)
    timeout = Keyword.get(opts, :timeout, 30_000)
    profiles_opt = Keyword.get(opts, :profiles, Keyword.get(opts, :profile, @default_profiles))
    required_tools = Keyword.get(opts, :required_tools, @default_required_tools)
    required_env_all = Keyword.get(opts, :required_env_all, [])
    required_env_any = Keyword.get(opts, :required_env_any, [])
    github_token_env_any = Keyword.get(opts, :github_token_env_any, @default_github_token_env_any)

    with {:ok, profiles} <- normalize_profiles(profiles_opt),
         {:ok, generic_checks} <-
           validate_generic_profile(
             shell_agent_mod,
             session_id,
             timeout,
             required_tools,
             required_env_all,
             required_env_any
           ),
         {:ok, github_checks} <-
           maybe_validate_github_profile(
             profiles,
             shell_agent_mod,
             session_id,
             timeout,
             github_token_env_any
           ) do
      checks =
        %{
          profiles: profiles,
          generic: generic_checks
        }
        |> maybe_put_github_checks(github_checks)
        |> maybe_put_legacy_fields(github_checks)

      missing = collect_missing(checks, github_checks)

      if missing == [] do
        {:ok, checks}
      else
        {:error,
         Error.execution("Shared runtime requirements failed", %{
           code: :shared_runtime_failed,
           missing: missing,
           checks: checks
         })}
      end
    end
  end

  defp validate_generic_profile(
         shell_agent_mod,
         session_id,
         timeout,
         required_tools,
         required_env_all,
         required_env_any
       ) do
    with {:ok, tool_checks} <- check_tools(shell_agent_mod, session_id, timeout, required_tools),
         {:ok, env_all_checks} <- check_env_vars(shell_agent_mod, session_id, timeout, required_env_all),
         {:ok, env_any_checks} <- check_env_vars(shell_agent_mod, session_id, timeout, required_env_any) do
      env_any_satisfied? =
        if map_size(env_any_checks) == 0 do
          true
        else
          Enum.any?(env_any_checks, fn {_key, present?} -> present? end)
        end

      {:ok,
       %{
         tools: tool_checks,
         env: %{
           required_all: env_all_checks,
           required_any: env_any_checks,
           any_satisfied: env_any_satisfied?
         }
       }}
    end
  end

  defp maybe_validate_github_profile(profiles, shell_agent_mod, session_id, timeout, token_env_any) do
    if :github in profiles do
      with {:ok, token_checks} <- check_env_vars(shell_agent_mod, session_id, timeout, token_env_any) do
        gh_present? = tool_present?(shell_agent_mod, session_id, "gh", timeout)
        github_token_visible? = Enum.any?(token_checks, fn {_key, present?} -> present? end)
        {gh_auth?, gh_login} = github_auth_ok?(gh_present?, shell_agent_mod, session_id, timeout)

        {:ok,
         %{
           gh: gh_present?,
           required_token_env_any: token_checks,
           github_token_visible: github_token_visible?,
           gh_auth: gh_auth?,
           gh_login: gh_login
         }}
      end
    else
      {:ok, nil}
    end
  end

  defp normalize_profiles(value) when is_atom(value), do: normalize_profiles([value])

  defp normalize_profiles(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn profile, {:ok, acc} ->
      cond do
        profile in @supported_profiles ->
          {:cont, {:ok, [profile | acc]}}

        true ->
          {:halt,
           {:error,
            Error.invalid("Unknown preflight profile", %{
              field: :profiles,
              value: profile,
              details: %{supported_profiles: @supported_profiles}
            })}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, @default_profiles}
      {:ok, profiles} -> {:ok, profiles |> Enum.reverse() |> Enum.uniq()}
      other -> other
    end
  end

  defp normalize_profiles(_value) do
    {:error, Error.invalid("profiles must be an atom or list", %{field: :profiles})}
  end

  defp check_tools(shell_agent_mod, session_id, timeout, tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, %{}}, fn tool, {:ok, acc} ->
      tool_name = to_string(tool)

      if valid_tool_name?(tool_name) do
        {:cont, {:ok, Map.put(acc, tool_name, tool_present?(shell_agent_mod, session_id, tool_name, timeout))}}
      else
        {:halt,
         {:error,
          Error.invalid("Invalid required tool name", %{
            field: :required_tools,
            value: tool,
            details: %{tool: tool}
          })}}
      end
    end)
  end

  defp check_tools(_shell_agent_mod, _session_id, _timeout, _tools) do
    {:error, Error.invalid("required_tools must be a list", %{field: :required_tools})}
  end

  defp check_env_vars(shell_agent_mod, session_id, timeout, keys) when is_list(keys) do
    keys
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, acc} ->
      env_key = to_string(key)

      if valid_env_var_name?(env_key) do
        cmd = "if [ -n \"${#{env_key}:-}\" ]; then echo present; else echo missing; fi"

        case Exec.run(shell_agent_mod, session_id, cmd, timeout: timeout) do
          {:ok, "present"} -> {:cont, {:ok, Map.put(acc, env_key, true)}}
          {:ok, "missing"} -> {:cont, {:ok, Map.put(acc, env_key, false)}}
          {:ok, _other} -> {:cont, {:ok, Map.put(acc, env_key, false)}}
          {:error, reason} -> {:halt, {:error, Error.execution("Env check failed", %{key: env_key, reason: reason})}}
        end
      else
        {:halt,
         {:error,
          Error.invalid("Invalid env var name", %{
            field: :required_env,
            value: key,
            details: %{key: key}
          })}}
      end
    end)
  end

  defp check_env_vars(_shell_agent_mod, _session_id, _timeout, _keys) do
    {:error, Error.invalid("required env keys must be a list", %{field: :required_env})}
  end

  defp collect_missing(checks, github_checks) do
    missing_tools =
      checks.generic.tools
      |> Enum.flat_map(fn
        {_tool, true} -> []
        {tool, false} -> [{:missing_tool, tool}]
      end)

    missing_env_all =
      checks.generic.env.required_all
      |> Enum.flat_map(fn
        {_key, true} -> []
        {key, false} -> [{:missing_env, key}]
      end)

    missing_env_any =
      if checks.generic.env.any_satisfied do
        []
      else
        [{:missing_env_any_of, Map.keys(checks.generic.env.required_any)}]
      end

    missing_github =
      case github_checks do
        nil ->
          []

        github ->
          []
          |> maybe_add_missing(github.gh, :missing_gh)
          |> maybe_add_missing(github.github_token_visible, :missing_github_token_env)
          |> maybe_add_missing(github.gh_auth, :missing_github_auth)
      end

    missing_tools ++ missing_env_all ++ missing_env_any ++ missing_github
  end

  defp tool_present?(shell_agent_mod, session_id, tool, timeout) do
    cmd = "command -v #{Exec.escape_path(tool)} >/dev/null 2>&1 && echo present || echo missing"

    case Exec.run(shell_agent_mod, session_id, cmd, timeout: timeout) do
      {:ok, "present"} -> true
      _ -> false
    end
  end

  defp github_auth_ok?(false, _shell_agent_mod, _session_id, _timeout), do: {false, nil}

  defp github_auth_ok?(true, shell_agent_mod, session_id, timeout) do
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

  defp maybe_put_github_checks(checks, nil), do: checks
  defp maybe_put_github_checks(checks, github_checks), do: Map.put(checks, :github, github_checks)

  defp maybe_put_legacy_fields(checks, nil), do: maybe_put_legacy_git(checks)

  defp maybe_put_legacy_fields(checks, github_checks) do
    checks
    |> Map.put(:gh, github_checks.gh)
    |> Map.put(:github_token_visible, github_checks.github_token_visible)
    |> Map.put(:gh_auth, github_checks.gh_auth)
    |> Map.put(:gh_login, github_checks.gh_login)
    |> maybe_put_legacy_git()
  end

  defp maybe_put_legacy_git(checks) do
    case Map.get(checks.generic.tools, "git") do
      nil -> checks
      present? -> Map.put(checks, :git, present?)
    end
  end

  defp maybe_add_missing(acc, true, _reason), do: acc
  defp maybe_add_missing(acc, false, reason), do: acc ++ [reason]

  defp valid_env_var_name?(value) when is_binary(value) do
    value != "" and Regex.match?(@env_var_name_regex, value)
  end

  defp valid_tool_name?(value) when is_binary(value) do
    value != "" and Regex.match?(@tool_name_regex, value)
  end
end
