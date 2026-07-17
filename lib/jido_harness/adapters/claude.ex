defmodule Jido.Harness.Adapters.Claude do
  @moduledoc "Claude Code CLI adapter using print-mode stream JSON."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.CLIArgs, Adapters.CLIMapper, Adapters.CLIStream}
  alias Jido.Harness.{Adapters.Helpers, Capabilities, Error, RunRequest}

  @provider_options [
    :cli_path,
    :fallback_model,
    :max_budget_usd,
    :fork_session,
    :settings,
    :betas
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :claude,
      name: "Claude Code",
      executable: "claude",
      docs_url: "https://docs.anthropic.com/en/docs/claude-code",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        usage?: true,
        native_cancel?: true
      },
      default_session_transport: :stream_json_resume,
      session_transports: [Jido.Harness.SessionTransportSpec.managed(:stream_json_resume)],
      normalized_options: [
        :model,
        :provider_session_id,
        :max_turns,
        :system_prompt,
        :allowed_tools,
        :disallowed_tools,
        :add_dirs,
        :mcp_config,
        :approval_mode,
        :sandbox_mode,
        :reasoning_effort
      ],
      provider_options: @provider_options,
      install: %{npm: "@anthropic-ai/claude-code"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(options),
         {:ok, argv} <- build_argv(request, options) do
      request = %{request | env: Helpers.merge_env(request, context.config)}
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      CLIStream.run(:claude, request, context, executable, argv, &CLIMapper.claude/1)
    end
  rescue
    exception ->
      {:error,
       Error.validation("invalid Claude options", provider: :claude, details: %{message: Exception.message(exception)})}
  end

  @impl true
  def status(config),
    do:
      Helpers.status(
        :claude,
        spec().executable,
        ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_API_KEY"],
        config,
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:claude, "@anthropic-ai/claude-code", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options) do
    with {:ok, settings} <- settings_value(options[:settings], request.sandbox_mode) do
      argv =
        ["--print", "--output-format", "stream-json", "--include-partial-messages", "--verbose"] ++
          CLIArgs.pair("--model", request.model) ++
          CLIArgs.pair("--resume", request.provider_session_id) ++
          CLIArgs.pair("--max-turns", request.max_turns) ++
          CLIArgs.pair("--system-prompt", request.system_prompt) ++
          CLIArgs.comma_pair("--allowedTools", request.allowed_tools) ++
          CLIArgs.comma_pair("--disallowedTools", request.disallowed_tools) ++
          CLIArgs.repeat("--add-dir", request.add_dirs) ++
          mcp_args(request.mcp_config) ++
          approval_args(request.approval_mode) ++
          CLIArgs.pair("--effort", request.reasoning_effort) ++
          CLIArgs.pair("--fallback-model", options[:fallback_model]) ++
          CLIArgs.pair("--max-budget-usd", options[:max_budget_usd]) ++
          CLIArgs.pair("--settings", settings) ++
          CLIArgs.comma_pair("--betas", options[:betas]) ++
          CLIArgs.flag("--fork-session", options[:fork_session]) ++
          ["--", request.prompt]

      {:ok, argv}
    end
  end

  defp validate_options(options) do
    cond do
      not optional_string?(options[:cli_path]) -> invalid(:cli_path, "a string")
      not optional_string?(options[:fallback_model]) -> invalid(:fallback_model, "a string")
      not optional_string?(options[:settings]) -> invalid(:settings, "a JSON string or file path")
      not optional_number?(options[:max_budget_usd]) -> invalid(:max_budget_usd, "a number")
      not optional_boolean?(options[:fork_session]) -> invalid(:fork_session, "a boolean")
      not optional_string_list?(options[:betas]) -> invalid(:betas, "a list of strings")
      true -> :ok
    end
  end

  defp settings_value(settings, :default), do: {:ok, settings}

  defp settings_value(settings, sandbox_mode) do
    with {:ok, base} <- read_settings(settings) do
      sandbox =
        case sandbox_mode do
          :read_only -> %{"enabled" => true, "filesystem" => %{"allowWrite" => []}}
          :workspace_write -> %{"enabled" => true}
          :unrestricted -> %{"enabled" => false}
        end

      {:ok, Jason.encode!(Map.put(base, "sandbox", sandbox))}
    end
  end

  defp read_settings(nil), do: {:ok, %{}}

  defp read_settings(settings) do
    case Jason.decode(settings) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> read_settings_file(settings)
    end
  end

  defp read_settings_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(contents) do
      {:ok, value}
    else
      _ -> {:error, Error.validation("Claude settings must contain a JSON object", provider: :claude)}
    end
  end

  defp mcp_args(nil), do: []
  defp mcp_args(value) when is_binary(value), do: ["--mcp-config", value]
  defp mcp_args(value) when is_map(value), do: ["--mcp-config", Jason.encode!(%{"mcpServers" => value})]
  defp approval_args(:default), do: []
  defp approval_args(:prompt), do: ["--permission-mode", "default"]
  defp approval_args(:auto_edit), do: ["--permission-mode", "acceptEdits"]
  defp approval_args(:auto_approve), do: ["--permission-mode", "bypassPermissions"]
  defp optional_string?(value), do: is_nil(value) or is_binary(value)
  defp optional_number?(value), do: is_nil(value) or is_number(value)
  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)
  defp optional_string_list?(value), do: is_nil(value) or (is_list(value) and Enum.all?(value, &is_binary/1))

  defp invalid(field, expected),
    do: {:error, Error.validation("Claude #{field} must be #{expected}", provider: :claude)}
end
