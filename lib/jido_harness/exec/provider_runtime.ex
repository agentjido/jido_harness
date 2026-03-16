defmodule Jido.Harness.Exec.ProviderRuntime do
  @moduledoc """
  Provider-specific runtime checks, bootstrap steps, and command templates.
  """

  alias Jido.Harness.Exec.Error
  alias Jido.Harness.Exec.ShellOps
  alias Jido.Harness.{Registry, RuntimeContract}
  alias Jido.Shell.Exec

  @doc """
  Loads and validates the provider runtime contract from the adapter.
  """
  @spec provider_runtime_contract(atom()) :: {:ok, RuntimeContract.t()} | {:error, term()}
  def provider_runtime_contract(provider) when is_atom(provider) do
    with {:ok, module} <- Registry.lookup(provider),
         :ok <- ensure_runtime_contract_callback(module, provider),
         {:ok, contract} <- safe_runtime_contract(module, provider),
         {:ok, normalized} <- normalize_contract(contract, provider),
         :ok <- ensure_command_templates(normalized, provider) do
      {:ok, normalized}
    end
  end

  @doc """
  Validates provider runtime prerequisites from the adapter contract.
  """
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

  @doc """
  Executes provider install/auth bootstrap steps and optional post-validation.
  """
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

  @doc """
  Builds a provider CLI command for `:triage` or `:coding` from contract templates.
  """
  @spec build_command(atom(), :triage | :coding, String.t()) :: {:ok, String.t()} | {:error, term()}
  def build_command(provider, phase, prompt_file)
      when is_atom(provider) and phase in [:triage, :coding] and is_binary(prompt_file) do
    with {:ok, contract} <- provider_runtime_contract(provider) do
      template =
        case phase do
          :triage -> contract.triage_command_template
          :coding -> contract.coding_command_template
        end

      if is_binary(template) and String.trim(template) != "" do
        escaped = Exec.escape_path(prompt_file)
        prompt_expr = "$(cat #{escaped})"

        {:ok,
         template
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
    all = contract.host_env_required_all
    any = contract.host_env_required_any

    with {:ok, all_results} <-
           ShellOps.check_env_vars(shell_agent_mod, session_id, timeout, all,
             field: :runtime_contract_env,
             invalid_message: "Invalid env var name in runtime contract",
             type_message: "runtime contract env keys must be a list"
           ),
         {:ok, any_results} <-
           ShellOps.check_env_vars(shell_agent_mod, session_id, timeout, any,
             field: :runtime_contract_env,
             invalid_message: "Invalid env var name in runtime contract",
             type_message: "runtime contract env keys must be a list"
           ) do
      {:ok,
       %{
         required_all: all_results,
         required_any: any_results,
         any_satisfied: any_requirement_satisfied?(any_results)
       }}
    end
  end

  defp validate_tool_contract(contract, shell_agent_mod, session_id, timeout) do
    ShellOps.check_tools(shell_agent_mod, session_id, timeout, contract.runtime_tools_required,
      field: :runtime_tools_required,
      invalid_message: "Invalid runtime tool name",
      type_message: "runtime_tools_required must be a list"
    )
  end

  defp validate_compatibility_probes(contract, shell_agent_mod, session_id, cwd, timeout) do
    collect_results(contract.compatibility_probes, &run_probe(&1, shell_agent_mod, session_id, cwd, timeout))
  end

  defp run_probe(probe, shell_agent_mod, session_id, cwd, timeout) when is_map(probe) do
    command = map_get(probe, :command)
    name = map_get(probe, :name, "probe")
    expect_all = normalize_list(map_get(probe, :expect_all, []))
    expect_any = normalize_list(map_get(probe, :expect_any, []))

    with :ok <- ensure_non_empty_command(command, :compatibility_probes, "Probe command is required", %{probe: name}) do
      case ShellOps.run_command(shell_agent_mod, session_id, cwd, command, timeout) do
        {:ok, output} ->
          {:ok,
           %{
             name: name,
             command: command,
             pass?: probe_passed?(output, expect_all, expect_any),
             output: output
           }}

        {:error, reason} ->
          {:error, Error.execution("Compatibility probe failed", %{probe: name, command: command, reason: reason})}
      end
    end
  end

  defp run_probe(_probe, _shell_agent_mod, _session_id, _cwd, _timeout) do
    {:error, Error.invalid("Probe must be a map", %{field: :compatibility_probes})}
  end

  defp execute_install_steps(contract, shell_agent_mod, session_id, cwd, timeout) do
    collect_results(contract.install_steps, &run_install_step(&1, shell_agent_mod, session_id, cwd, timeout))
  end

  defp run_install_step(step, shell_agent_mod, session_id, cwd, timeout) when is_map(step) do
    tool = map_get(step, :tool)
    command = map_get(step, :command)
    when_missing? = map_get(step, :when_missing, true)

    with :ok <- ensure_non_empty_command(command, :install_steps, "Install step command is required", %{step: step}),
         :ok <- validate_install_tool(tool) do
      maybe_execute_install_step(when_missing?, tool, shell_agent_mod, session_id, cwd, command, timeout)
    end
  end

  defp run_install_step(_step, _shell_agent_mod, _session_id, _cwd, _timeout) do
    {:error, Error.invalid("Install step must be a map", %{field: :install_steps})}
  end

  defp execute_auth_bootstrap_steps(contract, shell_agent_mod, session_id, cwd, timeout) do
    collect_results(
      contract.auth_bootstrap_steps,
      &run_auth_bootstrap_step(&1, shell_agent_mod, session_id, cwd, timeout)
    )
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

  defp ensure_runtime_contract_callback(module, provider) do
    if function_exported?(module, :runtime_contract, 0) do
      :ok
    else
      {:error,
       Error.invalid("Provider adapter must define runtime_contract/0", %{
         field: :runtime_contract,
         details: %{provider: provider, module: inspect(module)}
       })}
    end
  end

  defp safe_runtime_contract(module, provider) do
    {:ok, module.runtime_contract()}
  rescue
    reason ->
      {:error,
       Error.execution("Failed to fetch provider runtime contract", %{
         provider: provider,
         module: inspect(module),
         reason: reason
       })}
  end

  defp ensure_command_templates(contract, provider) do
    missing =
      []
      |> maybe_require_template(contract.triage_command_template, :triage_command_template)
      |> maybe_require_template(contract.coding_command_template, :coding_command_template)

    case missing do
      [] ->
        :ok

      fields ->
        {:error,
         Error.invalid("Provider runtime contract must include command templates", %{
           field: :runtime_contract,
           details: %{provider: provider, missing_fields: fields}
         })}
    end
  end

  defp maybe_require_template(acc, value, field) when is_binary(value) do
    if String.trim(value) == "", do: acc ++ [field], else: acc
  end

  defp maybe_require_template(acc, _value, field), do: acc ++ [field]

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

  defp any_requirement_satisfied?(checks) do
    map_size(checks) == 0 or Enum.any?(checks, fn {_key, present?} -> present? end)
  end

  defp collect_results(items, fun) when is_list(items) and is_function(fun, 1) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      other -> other
    end
  end

  defp ensure_non_empty_command(command, field, message, details) when is_binary(command) do
    if String.trim(command) == "" do
      {:error, Error.invalid(message, %{field: field, details: details})}
    else
      :ok
    end
  end

  defp ensure_non_empty_command(command, field, message, details) do
    {:error, Error.invalid(message, %{field: field, value: command, details: details})}
  end

  defp validate_install_tool(tool) when is_binary(tool) do
    if ShellOps.valid_tool_name?(tool) do
      :ok
    else
      {:error,
       Error.invalid("Install step tool name is invalid", %{
         field: :install_steps,
         value: tool,
         details: %{tool: tool}
       })}
    end
  end

  defp validate_install_tool(_tool), do: :ok

  defp maybe_execute_install_step(true, tool, shell_agent_mod, session_id, cwd, command, timeout)
       when is_binary(tool) do
    if ShellOps.tool_present?(shell_agent_mod, session_id, tool, timeout) do
      {:ok, %{tool: tool, status: :skipped, reason: :already_present}}
    else
      execute_install_command(tool, shell_agent_mod, session_id, cwd, command, timeout)
    end
  end

  defp maybe_execute_install_step(_when_missing?, tool, shell_agent_mod, session_id, cwd, command, timeout) do
    execute_install_command(tool, shell_agent_mod, session_id, cwd, command, timeout)
  end

  defp execute_install_command(tool, shell_agent_mod, session_id, cwd, command, timeout) do
    case ShellOps.run_command(shell_agent_mod, session_id, cwd, command, timeout) do
      {:ok, output} ->
        {:ok, %{tool: tool, status: :ok, output: output}}

      {:error, reason} ->
        {:error, Error.execution("Install step failed", %{tool: tool, reason: reason})}
    end
  end

  defp run_auth_bootstrap_step(command, shell_agent_mod, session_id, cwd, timeout) do
    with :ok <-
           ensure_non_empty_command(
             command,
             :auth_bootstrap_steps,
             "Auth bootstrap step must be a non-empty command",
             %{step: command}
           ) do
      case ShellOps.run_command(shell_agent_mod, session_id, cwd, command, timeout) do
        {:ok, output} ->
          {:ok, %{command: command, status: :ok, output: output}}

        {:error, reason} ->
          {:error, Error.execution("Auth bootstrap failed", %{command: command, reason: reason})}
      end
    end
  end

  defp probe_passed?(output, expect_all, expect_any) do
    Enum.all?(expect_all, &String.contains?(output, &1)) and
      (expect_any == [] or Enum.any?(expect_any, &String.contains?(output, &1)))
  end
end
