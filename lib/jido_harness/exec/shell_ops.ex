defmodule Jido.Harness.Exec.ShellOps do
  @moduledoc false

  alias Jido.Harness.Exec.Error
  alias Jido.Shell.Exec

  @env_var_name_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @tool_name_regex ~r/^[A-Za-z0-9._+-]+$/

  @doc "Checks named tools for availability within a shell session."
  @spec check_tools(module(), String.t(), timeout(), list(), keyword()) ::
          {:ok, %{optional(String.t()) => boolean()}} | {:error, term()}
  def check_tools(shell_agent_mod, session_id, timeout, tools, opts \\ [])
      when is_binary(session_id) and is_integer(timeout) do
    field = Keyword.fetch!(opts, :field)
    invalid_message = Keyword.fetch!(opts, :invalid_message)
    type_message = Keyword.fetch!(opts, :type_message)

    if is_list(tools) do
      Enum.reduce_while(tools, {:ok, %{}}, fn tool, {:ok, acc} ->
        accumulate_tool_check(tool, acc, shell_agent_mod, session_id, timeout, field, invalid_message)
      end)
    else
      {:error, Error.invalid(type_message, %{field: field})}
    end
  end

  @doc "Checks named environment variables for presence within a shell session."
  @spec check_env_vars(module(), String.t(), timeout(), list(), keyword()) ::
          {:ok, %{optional(String.t()) => boolean()}} | {:error, term()}
  def check_env_vars(shell_agent_mod, session_id, timeout, keys, opts \\ [])
      when is_binary(session_id) and is_integer(timeout) do
    field = Keyword.fetch!(opts, :field)
    invalid_message = Keyword.fetch!(opts, :invalid_message)
    type_message = Keyword.fetch!(opts, :type_message)

    if is_list(keys) do
      Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
        accumulate_env_check(key, acc, shell_agent_mod, session_id, timeout, field, invalid_message)
      end)
    else
      {:error, Error.invalid(type_message, %{field: field})}
    end
  end

  @doc "Returns true when a tool is available in the shell session PATH."
  @spec tool_present?(module(), String.t(), String.t(), timeout()) :: boolean()
  def tool_present?(shell_agent_mod, session_id, tool, timeout)
      when is_binary(session_id) and is_binary(tool) and is_integer(timeout) do
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

  @doc "Runs a shell command, optionally scoped to a working directory."
  @spec run_command(module(), String.t(), String.t() | nil, String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def run_command(shell_agent_mod, session_id, cwd, command, timeout)
      when is_binary(session_id) and is_binary(command) and is_integer(timeout) do
    if is_binary(cwd) and cwd != "" do
      Exec.run_in_dir(shell_agent_mod, session_id, cwd, command, timeout: timeout)
    else
      Exec.run(shell_agent_mod, session_id, command, timeout: timeout)
    end
  end

  @doc "Returns true when a tool name satisfies the harness runtime contract format."
  @spec valid_tool_name?(String.t()) :: boolean()
  def valid_tool_name?(value) when is_binary(value) do
    value != "" and Regex.match?(@tool_name_regex, value)
  end

  defp env_var_present?(shell_agent_mod, session_id, env_key, timeout) do
    cmd = "if [ -n \"${#{env_key}:-}\" ]; then echo present; else echo missing; fi"

    case Exec.run(shell_agent_mod, session_id, cmd, timeout: timeout) do
      {:ok, "present"} -> {:ok, true}
      {:ok, _} -> {:ok, false}
      {:error, reason} -> {:error, Error.execution("Env check failed", %{key: env_key, reason: reason})}
    end
  end

  defp validate_tool_name(tool_name, original, field, message) do
    if valid_tool_name?(tool_name) do
      :ok
    else
      {:error,
       Error.invalid(message, %{
         field: field,
         value: original,
         details: %{tool: original}
       })}
    end
  end

  defp validate_env_var_name(env_key, original, field, message) do
    if valid_env_var_name?(env_key) do
      :ok
    else
      {:error,
       Error.invalid(message, %{
         field: field,
         value: original,
         details: %{key: original}
       })}
    end
  end

  defp valid_env_var_name?(value) when is_binary(value) do
    value != "" and Regex.match?(@env_var_name_regex, value)
  end

  defp accumulate_tool_check(tool, acc, shell_agent_mod, session_id, timeout, field, invalid_message) do
    tool_name = to_string(tool)

    case validate_tool_name(tool_name, tool, field, invalid_message) do
      :ok ->
        {:cont, {:ok, Map.put(acc, tool_name, tool_present?(shell_agent_mod, session_id, tool_name, timeout))}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp accumulate_env_check(key, acc, shell_agent_mod, session_id, timeout, field, invalid_message) do
    env_key = to_string(key)

    with :ok <- validate_env_var_name(env_key, key, field, invalid_message),
         {:ok, present?} <- env_var_present?(shell_agent_mod, session_id, env_key, timeout) do
      {:cont, {:ok, Map.put(acc, env_key, present?)}}
    else
      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end
end
