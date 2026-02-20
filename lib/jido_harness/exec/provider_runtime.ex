defmodule Jido.Harness.Exec.ProviderRuntime do
  @moduledoc """
  Provider-specific runtime checks, bootstrap steps, and command templates.
  """

  alias Jido.Harness.{Registry, RuntimeContract}
  alias Jido.Harness.Exec.Error
  alias Jido.Shell.Exec

  @env_var_name_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @tool_name_regex ~r/^[A-Za-z0-9._+-]+$/

  @spec provider_runtime_contract(atom()) :: {:ok, RuntimeContract.t()} | {:error, term()}
  def provider_runtime_contract(provider) when is_atom(provider) do
    with {:ok, module} <- Registry.lookup(provider) do
      contract =
        if function_exported?(module, :runtime_contract, 0) do
          module.runtime_contract()
        else
          default_runtime_contract(provider)
        end

      normalize_contract(contract, provider)
    end
  end

  @spec validate_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate_provider_runtime(provider, session_id, opts \\ [])
      when is_atom(provider) and is_binary(session_id) and is_list(opts) do
    shell_agent_mod = Keyword.get(opts, :shell_agent_mod, Jido.Shell.Agent)
    timeout = Keyword.get(opts, :timeout, 30_000)
    cwd = Keyword.get(opts, :cwd)

    with {:ok, contract} <- provider_runtime_contract(provider),
         {:ok, env_checks} <- validate_env_contract(contract, shell_agent_mod, session_id, timeout),
         {:ok, tool_checks} <- validate_tool_contract(contract, shell_agent_mod, session_id, timeout),
         {:ok, probe_checks} <- validate_compatibility_probes(contract, shell_agent_mod, session_id, cwd, timeout) do
      checks = %{
        env: env_checks,
        tools: tool_checks,
        probes: probe_checks
      }

      missing = collect_missing(checks)

      if missing == [] do
        {:ok, %{provider: provider, runtime_contract: contract, checks: checks}}
      else
        {:error,
         Error.execution("Provider runtime requirements failed", %{
           code: :provider_runtime_failed,
           provider: provider,
           missing: missing,
           checks: checks
         })}
      end
    end
  end

  @spec bootstrap_provider_runtime(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bootstrap_provider_runtime(provider, session_id, opts \\ [])
      when is_atom(provider) and is_binary(session_id) and is_list(opts) do
    shell_agent_mod = Keyword.get(opts, :shell_agent_mod, Jido.Shell.Agent)
    timeout = Keyword.get(opts, :timeout, 60_000)
    cwd = Keyword.get(opts, :cwd)
    validate_after_bootstrap? = Keyword.get(opts, :validate_after_bootstrap, true)
    validation_timeout = Keyword.get(opts, :validation_timeout, timeout)

    with {:ok, contract} <- provider_runtime_contract(provider),
         {:ok, install_results} <-
           execute_install_steps(contract, shell_agent_mod, session_id, cwd, timeout),
         {:ok, auth_results} <-
           execute_auth_bootstrap_steps(contract, shell_agent_mod, session_id, cwd, timeout),
         {:ok, post_validation} <-
           maybe_validate_after_bootstrap(
             validate_after_bootstrap?,
             provider,
             session_id,
             shell_agent_mod,
             cwd,
             validation_timeout
           ) do
      {:ok,
       %{
         provider: provider,
         runtime_contract: contract,
         install_results: install_results,
         auth_bootstrap_results: auth_results,
         post_validation: post_validation
       }}
    end
  end

  @spec build_command(atom(), :triage | :coding, String.t()) :: {:ok, String.t()} | {:error, term()}
  def build_command(provider, phase, prompt_file)
      when is_atom(provider) and phase in [:triage, :coding] and is_binary(prompt_file) do
    with {:ok, contract} <- provider_runtime_contract(provider) do
      template =
        case phase do
          :triage -> contract.triage_command_template
          :coding -> contract.coding_command_template
        end

      command = template || default_command_template(provider, phase)

      if is_binary(command) and String.trim(command) != "" do
        escaped = Exec.escape_path(prompt_file)
        prompt_expr = "$(cat #{escaped})"

        {:ok,
         command
         |> String.replace("{{prompt_file}}", escaped)
         |> String.replace("{{prompt}}", prompt_expr)}
      else
        {:error,
         Error.invalid("Missing command template for provider phase", %{
           field: :command_template,
           details: %{provider: provider, phase: phase}
         })}
      end
    end
  end

  defp normalize_contract(%RuntimeContract{} = contract, _provider), do: {:ok, contract}

  defp normalize_contract(contract, provider) when is_map(contract) do
    attrs =
      contract
      |> map_put_new(:provider, provider)
      |> stringify_keys()

    case RuntimeContract.new(attrs) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         Error.invalid("Invalid provider runtime contract", %{
           field: :runtime_contract,
           details: %{provider: provider, reason: reason}
         })}
    end
  end

  defp normalize_contract(_contract, provider) do
    {:error,
     Error.invalid("Runtime contract must be a map or struct", %{
       field: :runtime_contract,
       details: %{provider: provider}
     })}
  end

  defp validate_env_contract(contract, shell_agent_mod, session_id, timeout) do
    all = contract.host_env_required_all || []
    any = contract.host_env_required_any || []

    with {:ok, all_results} <- check_env_vars(shell_agent_mod, session_id, all, timeout),
         {:ok, any_results} <- check_env_vars(shell_agent_mod, session_id, any, timeout) do
      any_ok =
        if any == [] do
          true
        else
          Enum.any?(any_results, fn {_key, present?} -> present? end)
        end

      {:ok, %{required_all: all_results, required_any: any_results, any_satisfied: any_ok}}
    end
  end

  defp validate_tool_contract(contract, shell_agent_mod, session_id, timeout) do
    (contract.runtime_tools_required || [])
    |> Enum.reduce_while({:ok, %{}}, fn tool, {:ok, acc} ->
      tool_name = to_string(tool)

      if valid_tool_name?(tool_name) do
        {:cont, {:ok, Map.put(acc, tool_name, tool_present?(shell_agent_mod, session_id, tool_name, timeout))}}
      else
        {:halt,
         {:error,
          Error.invalid("Invalid runtime tool name", %{
            field: :runtime_tools_required,
            value: tool,
            details: %{tool: tool}
          })}}
      end
    end)
  end

  defp validate_compatibility_probes(contract, shell_agent_mod, session_id, cwd, timeout) do
    probes = contract.compatibility_probes || []

    probes
    |> Enum.reduce_while({:ok, []}, fn probe, {:ok, acc} ->
      case run_probe(probe, shell_agent_mod, session_id, cwd, timeout) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp run_probe(probe, shell_agent_mod, session_id, cwd, timeout) when is_map(probe) do
    command = map_get(probe, :command)
    name = map_get(probe, :name, "probe")
    expect_all = normalize_list(map_get(probe, :expect_all, []))
    expect_any = normalize_list(map_get(probe, :expect_any, []))

    if not is_binary(command) or String.trim(command) == "" do
      {:error,
       Error.invalid("Probe command is required", %{
         field: :compatibility_probes,
         details: %{probe: name}
       })}
    else
      runner =
        if is_binary(cwd) and cwd != "" do
          Exec.run_in_dir(shell_agent_mod, session_id, cwd, command, timeout: timeout)
        else
          Exec.run(shell_agent_mod, session_id, command, timeout: timeout)
        end

      case runner do
        {:ok, output} ->
          has_all = Enum.all?(expect_all, &String.contains?(output, &1))
          has_any = if expect_any == [], do: true, else: Enum.any?(expect_any, &String.contains?(output, &1))
          pass? = has_all and has_any

          {:ok, %{name: name, command: command, pass?: pass?, output: output}}

        {:error, reason} ->
          {:error,
           Error.execution("Compatibility probe failed", %{
             probe: name,
             command: command,
             reason: reason
           })}
      end
    end
  end

  defp run_probe(_probe, _shell_agent_mod, _session_id, _cwd, _timeout) do
    {:error, Error.invalid("Probe must be a map", %{field: :compatibility_probes})}
  end

  defp execute_install_steps(contract, shell_agent_mod, session_id, cwd, timeout) do
    steps = contract.install_steps || []

    steps
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, acc} ->
      case run_install_step(step, shell_agent_mod, session_id, cwd, timeout) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp run_install_step(step, shell_agent_mod, session_id, cwd, timeout) when is_map(step) do
    tool = map_get(step, :tool)
    command = map_get(step, :command)
    when_missing? = map_get(step, :when_missing, true)

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error,
         Error.invalid("Install step command is required", %{
           field: :install_steps,
           details: %{step: step}
         })}

      is_binary(tool) and not valid_tool_name?(tool) ->
        {:error,
         Error.invalid("Install step tool name is invalid", %{
           field: :install_steps,
           value: tool,
           details: %{tool: tool}
         })}

      when_missing? == true and is_binary(tool) and tool_present?(shell_agent_mod, session_id, tool, timeout) ->
        {:ok, %{tool: tool, status: :skipped, reason: :already_present}}

      true ->
        case run_command(shell_agent_mod, session_id, cwd, command, timeout) do
          {:ok, output} -> {:ok, %{tool: tool, status: :ok, output: output}}
          {:error, reason} -> {:error, Error.execution("Install step failed", %{tool: tool, reason: reason})}
        end
    end
  end

  defp run_install_step(_step, _shell_agent_mod, _session_id, _cwd, _timeout) do
    {:error, Error.invalid("Install step must be a map", %{field: :install_steps})}
  end

  defp execute_auth_bootstrap_steps(contract, shell_agent_mod, session_id, cwd, timeout) do
    steps = contract.auth_bootstrap_steps || []

    steps
    |> Enum.reduce_while({:ok, []}, fn command, {:ok, acc} ->
      if is_binary(command) and String.trim(command) != "" do
        case run_command(shell_agent_mod, session_id, cwd, command, timeout) do
          {:ok, output} ->
            {:cont, {:ok, [%{command: command, status: :ok, output: output} | acc]}}

          {:error, reason} ->
            {:halt, {:error, Error.execution("Auth bootstrap failed", %{command: command, reason: reason})}}
        end
      else
        {:halt,
         {:error,
          Error.invalid("Auth bootstrap step must be a non-empty command", %{
            field: :auth_bootstrap_steps,
            value: command,
            details: %{step: command}
          })}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  defp run_command(shell_agent_mod, session_id, cwd, command, timeout) do
    if is_binary(cwd) and cwd != "" do
      Exec.run_in_dir(shell_agent_mod, session_id, cwd, command, timeout: timeout)
    else
      Exec.run(shell_agent_mod, session_id, command, timeout: timeout)
    end
  end

  defp check_env_vars(shell_agent_mod, session_id, keys, timeout) do
    keys
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, acc} ->
      env_key = to_string(key)

      if valid_env_var_name?(env_key) do
        cmd = "if [ -n \"${#{env_key}:-}\" ]; then echo present; else echo missing; fi"

        case Exec.run(shell_agent_mod, session_id, cmd, timeout: timeout) do
          {:ok, "present"} -> {:cont, {:ok, Map.put(acc, env_key, true)}}
          {:ok, "missing"} -> {:cont, {:ok, Map.put(acc, env_key, false)}}
          {:ok, _} -> {:cont, {:ok, Map.put(acc, env_key, false)}}
          {:error, reason} -> {:halt, {:error, Error.execution("Env check failed", %{key: env_key, reason: reason})}}
        end
      else
        {:halt,
         {:error,
          Error.invalid("Invalid env var name in runtime contract", %{
            field: :runtime_contract_env,
            value: key,
            details: %{key: key}
          })}}
      end
    end)
  end

  defp tool_present?(shell_agent_mod, session_id, tool, timeout) do
    if valid_tool_name?(tool) do
      cmd = "command -v #{Exec.escape_path(tool)} >/dev/null 2>&1 && echo present || echo missing"

      case Exec.run(shell_agent_mod, session_id, cmd, timeout: timeout) do
        {:ok, "present"} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp collect_missing(checks) do
    missing_env_all =
      checks.env.required_all
      |> Enum.flat_map(fn
        {_key, true} -> []
        {key, false} -> [{:missing_env, key}]
      end)

    missing_env_any =
      if checks.env.any_satisfied do
        []
      else
        [{:missing_env_any_of, Map.keys(checks.env.required_any)}]
      end

    missing_tools =
      checks.tools
      |> Enum.flat_map(fn
        {_tool, true} -> []
        {tool, false} -> [{:missing_tool, tool}]
      end)

    missing_probes =
      checks.probes
      |> Enum.flat_map(fn
        %{pass?: true} -> []
        %{name: name} -> [{:probe_failed, name}]
      end)

    missing_env_all ++ missing_env_any ++ missing_tools ++ missing_probes
  end

  defp default_runtime_contract(provider) do
    RuntimeContract.new!(%{
      provider: provider,
      host_env_required_any: [],
      host_env_required_all: [],
      sprite_env_forward: ["GH_TOKEN", "GITHUB_TOKEN"],
      sprite_env_injected: %{
        "GH_PROMPT_DISABLED" => "1",
        "GIT_TERMINAL_PROMPT" => "0"
      },
      runtime_tools_required: [],
      compatibility_probes: [],
      install_steps: [],
      auth_bootstrap_steps: [],
      triage_command_template: nil,
      coding_command_template: nil,
      success_markers: []
    })
  end

  defp default_command_template(:claude, _phase) do
    "if command -v timeout >/dev/null 2>&1; then timeout 180 claude -p --output-format stream-json --include-partial-messages --no-session-persistence --verbose --dangerously-skip-permissions \"{{prompt}}\"; else claude -p --output-format stream-json --include-partial-messages --no-session-persistence --verbose --dangerously-skip-permissions \"{{prompt}}\"; fi"
  end

  defp default_command_template(:amp, _phase) do
    "if command -v timeout >/dev/null 2>&1; then timeout 180 amp -x --stream-json --dangerously-allow-all --no-color < {{prompt_file}}; else amp -x --stream-json --dangerously-allow-all --no-color < {{prompt_file}}; fi"
  end

  defp default_command_template(:codex, :triage) do
    "if command -v timeout >/dev/null 2>&1; then timeout 120 codex exec --json --full-auto - < {{prompt_file}}; else codex exec --json --full-auto - < {{prompt_file}}; fi"
  end

  defp default_command_template(:codex, :coding) do
    "if command -v timeout >/dev/null 2>&1; then timeout 180 codex exec --json --dangerously-bypass-approvals-and-sandbox - < {{prompt_file}}; else codex exec --json --dangerously-bypass-approvals-and-sandbox - < {{prompt_file}}; fi"
  end

  defp default_command_template(:gemini, :triage) do
    "if command -v timeout >/dev/null 2>&1; then timeout 120 gemini --output-format stream-json \"{{prompt}}\"; else gemini --output-format stream-json \"{{prompt}}\"; fi"
  end

  defp default_command_template(:gemini, :coding) do
    "if command -v timeout >/dev/null 2>&1; then timeout 180 gemini --output-format stream-json --approval-mode yolo \"{{prompt}}\"; else gemini --output-format stream-json --approval-mode yolo \"{{prompt}}\"; fi"
  end

  defp default_command_template(_provider, _phase), do: nil

  defp map_get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_put_new(map, key, value) when is_map(map) and is_atom(key) do
    if Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key)) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp normalize_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalize_list(nil), do: []
  defp normalize_list(value), do: [to_string(value)]

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp maybe_validate_after_bootstrap(false, _provider, _session_id, _shell_agent_mod, _cwd, _timeout),
    do: {:ok, nil}

  defp maybe_validate_after_bootstrap(true, provider, session_id, shell_agent_mod, cwd, timeout) do
    case validate_provider_runtime(
           provider,
           session_id,
           shell_agent_mod: shell_agent_mod,
           cwd: cwd,
           timeout: timeout
         ) do
      {:ok, validated} ->
        {:ok, validated.checks}

      {:error, reason} ->
        {:error,
         Error.execution("Provider runtime bootstrap verification failed", %{
           provider: provider,
           reason: reason
         })}
    end
  end

  defp valid_env_var_name?(value) when is_binary(value) do
    value != "" and Regex.match?(@env_var_name_regex, value)
  end

  defp valid_env_var_name?(_), do: false

  defp valid_tool_name?(value) when is_binary(value) do
    value != "" and Regex.match?(@tool_name_regex, value)
  end

  defp valid_tool_name?(_), do: false
end
