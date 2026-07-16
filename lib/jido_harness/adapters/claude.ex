defmodule Jido.Harness.Adapters.Claude do
  @moduledoc "Claude Agent SDK-backed harness adapter."
  @behaviour Jido.Harness.Adapter

  alias ClaudeAgentSDK.Options
  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Adapters.SDKMapper, Capabilities, Error, RunRequest}

  @provider_options [
    :cli_path,
    :verbose,
    :preferred_transport,
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
        usage?: true
      },
      normalized_options: [
        :model,
        :session_id,
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
    provider = Helpers.provider_options(request.provider_options, @provider_options)

    attrs =
      provider
      |> Map.drop([:cli_path])
      |> Map.merge(%{
        model: request.model,
        max_turns: request.max_turns,
        timeout_ms: Helpers.sdk_timeout(request.runtime_timeout_ms),
        system_prompt: request.system_prompt,
        allowed_tools: request.allowed_tools,
        disallowed_tools: request.disallowed_tools,
        add_dirs: request.add_dirs,
        permission_mode: permission_mode(request.approval_mode),
        sandbox: sandbox(request.sandbox_mode),
        cwd: request.cwd,
        env: Map.merge(Map.get(context.config, :env, %{}), request.env),
        max_thinking_tokens: thinking_tokens(request.reasoning_effort),
        output_format: :stream_json,
        include_partial_messages: true,
        path_to_claude_code_executable: provider[:cli_path] || Map.get(context.config, :cli_path)
      })
      |> Map.merge(mcp(request.mcp_config))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    options = Options.new(attrs)
    _ = Options.to_args(options)
    sdk = Map.get(context.config, :sdk_module, ClaudeAgentSDK)

    source =
      if request.session_id do
        sdk.resume(request.session_id, request.prompt, options)
      else
        sdk.query(request.prompt, options)
      end

    {:ok, Stream.flat_map(source, &SDKMapper.claude/1)}
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

  defp permission_mode(:default), do: nil
  defp permission_mode(:prompt), do: :default
  defp permission_mode(:auto_edit), do: :accept_edits
  defp permission_mode(:auto_approve), do: :bypass_permissions
  defp sandbox(:default), do: nil
  defp sandbox(:read_only), do: %{enabled: true, filesystem: %{allow_write: []}}
  defp sandbox(:workspace_write), do: %{enabled: true}
  defp sandbox(:unrestricted), do: nil
  defp thinking_tokens(nil), do: nil
  defp thinking_tokens(:low), do: 1_024
  defp thinking_tokens(:medium), do: 4_096
  defp thinking_tokens(:high), do: 16_384
  defp mcp(nil), do: %{}
  defp mcp(value) when is_map(value), do: %{mcp_servers: value}
  defp mcp(value) when is_binary(value), do: %{mcp_config: value}
end
