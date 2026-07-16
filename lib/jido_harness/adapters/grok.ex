defmodule Jido.Harness.Adapters.Grok do
  @moduledoc "Official xAI Grok CLI adapter using headless streaming JSON."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{
    AdapterSpec,
    Adapters.CLIStream,
    Adapters.Helpers,
    Adapters.JSONMapper,
    Capabilities,
    Error,
    RunRequest
  }

  @provider_options [:cli_path, :allow_rules, :deny_rules, :fork_session, :continue, :extra_args]
  @reserved_args [
    "-p",
    "--no-auto-update",
    "--no-alt-screen",
    "--output-format",
    "--model",
    "--cwd",
    "--resume",
    "--max-turns",
    "--system-prompt-override",
    "--tools",
    "--disallowed-tools",
    "--permission-mode",
    "--sandbox",
    "--effort",
    "--allow",
    "--deny",
    "--fork-session",
    "--continue"
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :grok,
      name: "Grok",
      executable: "grok",
      docs_url: "https://docs.x.ai/build/cli/reference",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        usage?: true,
        native_cancel?: true
      },
      normalized_options: [
        :model,
        :session_id,
        :max_turns,
        :system_prompt,
        :allowed_tools,
        :disallowed_tools,
        :approval_mode,
        :sandbox_mode,
        :reasoning_effort
      ],
      provider_options: @provider_options,
      install: %{npm: "@xai-official/grok"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(request, options),
         {:ok, argv} <- build_argv(request, options) do
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      CLIStream.run(:grok, request, context, executable, argv, &JSONMapper.map(:grok, &1))
    end
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:grok, spec().executable, ["XAI_API_KEY"], config,
        version_argv: ["version"],
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:grok, "@xai-official/grok", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options) do
    with {:ok, extra_args} <- extra_args(options[:extra_args]),
         {:ok, allow_rules} <- string_list(options[:allow_rules], :allow_rules),
         {:ok, deny_rules} <- string_list(options[:deny_rules], :deny_rules) do
      argv =
        ["--no-auto-update", "--no-alt-screen", "-p", request.prompt, "--output-format", "streaming-json"] ++
          pair("--model", request.model) ++
          pair("--cwd", request.cwd) ++
          pair("--resume", request.session_id) ++
          pair("--max-turns", request.max_turns) ++
          pair("--system-prompt-override", request.system_prompt) ++
          list_pair("--tools", request.allowed_tools) ++
          list_pair("--disallowed-tools", request.disallowed_tools) ++
          approval(request.approval_mode) ++
          sandbox(request.sandbox_mode) ++
          pair("--effort", request.reasoning_effort) ++
          repeat("--allow", allow_rules) ++
          repeat("--deny", deny_rules) ++
          flag("--fork-session", options[:fork_session]) ++
          flag("--continue", options[:continue]) ++ extra_args

      {:ok, argv}
    end
  end

  defp validate_options(%{session_id: session_id}, %{continue: true}) when is_binary(session_id),
    do: {:error, Error.validation("Grok session_id and provider continue cannot be combined", provider: :grok)}

  defp validate_options(_request, _options), do: :ok

  defp approval(:default), do: []
  defp approval(:prompt), do: ["--permission-mode", "default"]
  defp approval(:auto_edit), do: ["--permission-mode", "acceptEdits"]
  defp approval(:auto_approve), do: ["--permission-mode", "bypassPermissions"]
  defp sandbox(:default), do: []
  defp sandbox(:read_only), do: ["--sandbox", "read-only"]
  defp sandbox(:workspace_write), do: ["--sandbox", "workspace"]
  defp sandbox(:unrestricted), do: ["--sandbox", "off"]
  defp flag(flag, true), do: [flag]
  defp flag(_flag, _value), do: []
  defp list_pair(_flag, nil), do: []
  defp list_pair(flag, values), do: [flag, Enum.join(values, ",")]
  defp extra_args(nil), do: {:ok, []}

  defp extra_args(args) when is_list(args) do
    cond do
      not Enum.all?(args, &is_binary/1) ->
        extra_args(:invalid)

      shadow = Enum.find(args, &reserved_arg?(&1, @reserved_args)) ->
        {:error,
         Error.validation("Grok extra_args cannot shadow managed options",
           provider: :grok,
           details: %{argument: shadow}
         )}

      true ->
        {:ok, args}
    end
  end

  defp extra_args(_args), do: {:error, Error.validation("Grok extra_args must be a list of strings", provider: :grok)}
  defp string_list(nil, _field), do: {:ok, []}

  defp string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: string_list(:invalid, field)
  end

  defp string_list(_values, field),
    do: {:error, Error.validation("Grok #{field} must be a list of strings", provider: :grok)}

  defp pair(_flag, nil), do: []
  defp pair(flag, value), do: [flag, to_string(value)]
  defp repeat(flag, values), do: Enum.flat_map(values, &pair(flag, &1))

  defp reserved_arg?(argument, reserved) do
    argument in reserved or Enum.any?(reserved, &String.starts_with?(argument, &1 <> "="))
  end
end
