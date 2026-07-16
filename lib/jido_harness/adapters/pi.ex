defmodule Jido.Harness.Adapters.Pi do
  @moduledoc "Official Pi coding-agent adapter using JSON event-stream mode."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.CLIStream, Adapters.Helpers, Capabilities, Error, RunRequest}

  @auth_envs [
    "AI_GATEWAY_API_KEY",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_OAUTH_TOKEN",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_PROFILE",
    "AZURE_OPENAI_API_KEY",
    "CEREBRAS_API_KEY",
    "CLOUDFLARE_API_KEY",
    "DEEPSEEK_API_KEY",
    "FIREWORKS_API_KEY",
    "GEMINI_API_KEY",
    "GROQ_API_KEY",
    "HF_TOKEN",
    "KIMI_API_KEY",
    "MINIMAX_API_KEY",
    "MISTRAL_API_KEY",
    "MOONSHOT_API_KEY",
    "NVIDIA_API_KEY",
    "OPENAI_API_KEY",
    "OPENCODE_API_KEY",
    "OPENROUTER_API_KEY",
    "TOGETHER_API_KEY",
    "XAI_API_KEY",
    "XIAOMI_API_KEY",
    "XIAOMI_TOKEN_PLAN_AMS_API_KEY",
    "XIAOMI_TOKEN_PLAN_CN_API_KEY",
    "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
    "ZAI_API_KEY",
    "ZAI_CODING_CN_API_KEY"
  ]

  @provider_options [
    :cli_path,
    :model_provider,
    :continue,
    :fork_session,
    :no_session,
    :session_dir,
    :session_name,
    :project_trust,
    :extensions,
    :skills,
    :no_extensions,
    :no_skills,
    :no_context_files,
    :offline,
    :extra_args
  ]

  @read_only_tools ["read", "grep", "find", "ls"]

  @reserved_args [
    "--mode",
    "--print",
    "-p",
    "--provider",
    "--model",
    "--api-key",
    "--thinking",
    "--session",
    "--session-id",
    "--continue",
    "-c",
    "--resume",
    "-r",
    "--fork",
    "--no-session",
    "--session-dir",
    "--name",
    "-n",
    "--tools",
    "-t",
    "--no-tools",
    "-nt",
    "--no-builtin-tools",
    "-nbt",
    "--exclude-tools",
    "-xt",
    "--system-prompt",
    "--append-system-prompt",
    "--approve",
    "-a",
    "--no-approve",
    "-na",
    "--extension",
    "-e",
    "--skill",
    "--no-extensions",
    "--no-skills",
    "--no-context-files",
    "-nc",
    "--offline",
    "--export",
    "--list-models",
    "--help",
    "-h",
    "--version",
    "-v"
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :pi,
      name: "Pi",
      executable: "pi",
      docs_url: "https://github.com/earendil-works/pi/tree/main/packages/coding-agent",
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
        :system_prompt,
        :allowed_tools,
        :disallowed_tools,
        :approval_mode,
        :sandbox_mode,
        :attachments,
        :reasoning_effort
      ],
      normalized_values: %{
        approval_mode: [:default, :auto_approve],
        sandbox_mode: [:default, :read_only, :unrestricted]
      },
      provider_options: @provider_options,
      install: %{npm: "@earendil-works/pi-coding-agent", npm_args: ["--ignore-scripts"]}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with {:ok, argv} <- build_argv(request, options) do
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      CLIStream.run(:pi, prepare_request(request), context, executable, argv, &map_event/1)
    end
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:pi, spec().executable, @auth_envs, config,
        capabilities: spec().capabilities,
        compatibility_argv: ["--help"],
        compatibility_pattern: "--mode"
      )

  @impl true
  def install(_config, options),
    do: Helpers.install_npm(:pi, "@earendil-works/pi-coding-agent", options, ["--ignore-scripts"])

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def prepare_request(%RunRequest{} = request) do
    env = request.env |> Map.put("PI_SKIP_VERSION_CHECK", "1") |> Map.put("PI_TELEMETRY", "0")
    %{request | env: env}
  end

  @doc false
  def build_argv(%RunRequest{} = request, options) do
    with :ok <- validate_options(request, options),
         {:ok, trust_args} <- project_trust(options[:project_trust]),
         {:ok, tool_args} <- tool_args(request),
         {:ok, extensions} <- string_list(options[:extensions], :extensions),
         {:ok, skills} <- string_list(options[:skills], :skills),
         {:ok, extra_args} <- extra_args(options[:extra_args]) do
      argv =
        ["--mode", "json"] ++
          pair("--provider", options[:model_provider]) ++
          pair("--model", request.model) ++
          pair("--thinking", request.reasoning_effort) ++
          pair("--session", request.session_id) ++
          flag("--continue", options[:continue]) ++
          pair("--fork", options[:fork_session]) ++
          flag("--no-session", options[:no_session]) ++
          pair("--session-dir", options[:session_dir]) ++
          pair("--name", options[:session_name]) ++
          tool_args ++
          list_pair("--exclude-tools", request.disallowed_tools) ++
          pair("--system-prompt", request.system_prompt) ++
          trust_args ++
          repeat("--extension", extensions) ++
          repeat("--skill", skills) ++
          flag("--no-extensions", options[:no_extensions]) ++
          flag("--no-skills", options[:no_skills]) ++
          flag("--no-context-files", options[:no_context_files]) ++
          flag("--offline", options[:offline]) ++
          extra_args ++ Enum.map(request.attachments, &("@" <> &1)) ++ [request.prompt]

      {:ok, argv}
    end
  end

  @doc false
  def map_event(%{"type" => "session", "id" => session_id} = raw) do
    [Helpers.event(:pi, :session_started, session_id, raw, raw)]
  end

  def map_event(%{"type" => "turn_start"} = raw),
    do: [Helpers.event(:pi, :turn_started, nil, %{}, raw)]

  def map_event(%{"type" => "turn_end"} = raw),
    do: [Helpers.event(:pi, :turn_completed, nil, %{}, raw)]

  def map_event(
        %{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => text}
        } = raw
      )
      when is_binary(text),
      do: [Helpers.event(:pi, :output_text_delta, nil, %{"text" => text}, raw)]

  def map_event(
        %{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => text}
        } = raw
      )
      when is_binary(text),
      do: [Helpers.event(:pi, :thinking_delta, nil, %{"text" => text}, raw)]

  def map_event(%{"type" => "message_end", "message" => %{"role" => "assistant"} = message} = raw) do
    text = content_text(Map.get(message, "content"))
    usage = Map.get(message, "usage")

    []
    |> maybe_event(text != "", fn ->
      Helpers.event(:pi, :output_text_final, nil, %{"text" => text}, raw)
    end)
    |> maybe_event(is_map(usage), fn -> Helpers.event(:pi, :usage, nil, usage, raw) end)
    |> case do
      [] -> [provider_event(raw)]
      events -> events
    end
  end

  def map_event(%{"type" => "tool_execution_start"} = raw) do
    [
      Helpers.event(
        :pi,
        :tool_call,
        nil,
        %{
          "call_id" => Map.get(raw, "toolCallId"),
          "name" => Map.get(raw, "toolName"),
          "input" => Map.get(raw, "args", %{})
        },
        raw
      )
    ]
  end

  def map_event(%{"type" => "tool_execution_end"} = raw) do
    [
      Helpers.event(
        :pi,
        :tool_result,
        nil,
        %{
          "call_id" => Map.get(raw, "toolCallId"),
          "name" => Map.get(raw, "toolName"),
          "output" => Map.get(raw, "result"),
          "is_error" => Map.get(raw, "isError", false)
        },
        raw
      )
    ]
  end

  def map_event(%{"type" => "agent_end", "willRetry" => false, "messages" => messages} = raw)
      when is_list(messages) do
    case last_assistant(messages) do
      %{"stopReason" => "error"} = message ->
        error = Map.get(message, "errorMessage", "Pi request failed")
        [Helpers.event(:pi, :session_failed, nil, %{"error" => error}, raw)]

      %{"stopReason" => "aborted"} = message ->
        reason = Map.get(message, "errorMessage", "Pi request aborted")
        [Helpers.event(:pi, :session_cancelled, nil, %{"reason" => reason}, raw)]

      _message ->
        [provider_event(raw)]
    end
  end

  def map_event(raw) when is_map(raw), do: [provider_event(raw)]

  def map_event(raw),
    do: [Helpers.event(:pi, :provider_event, nil, %{"mapped" => false, "value_type" => value_type(raw)}, raw)]

  defp validate_options(%{session_id: session_id}, %{continue: true}) when is_binary(session_id),
    do: conflict("session_id and provider continue")

  defp validate_options(%{session_id: session_id}, %{fork_session: fork})
       when is_binary(session_id) and is_binary(fork),
       do: conflict("session_id and provider fork_session")

  defp validate_options(_request, %{continue: true, fork_session: fork}) when is_binary(fork),
    do: conflict("provider continue and fork_session")

  defp validate_options(%{session_id: session_id}, %{no_session: true}) when is_binary(session_id),
    do: conflict("session_id and provider no_session")

  defp validate_options(_request, %{continue: true, no_session: true}),
    do: conflict("provider continue and no_session")

  defp validate_options(_request, %{fork_session: fork, no_session: true}) when is_binary(fork),
    do: conflict("provider fork_session and no_session")

  defp validate_options(_request, _options), do: :ok

  defp conflict(fields), do: {:error, Error.validation("Pi #{fields} cannot be combined", provider: :pi)}

  defp content_text(text) when is_binary(text), do: text

  defp content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> IO.iodata_to_binary()
  end

  defp content_text(_content), do: ""

  defp last_assistant(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&match?(%{"role" => "assistant"}, &1))
  end

  defp maybe_event(events, true, function), do: events ++ [function.()]
  defp maybe_event(events, false, _function), do: events

  defp provider_event(raw),
    do: Helpers.event(:pi, :provider_event, nil, %{"type" => Map.get(raw, "type"), "mapped" => false}, raw)

  defp project_trust(nil), do: {:ok, []}
  defp project_trust(:default), do: {:ok, []}
  defp project_trust(:approve), do: {:ok, ["--approve"]}
  defp project_trust(:deny), do: {:ok, ["--no-approve"]}

  defp project_trust(_value),
    do: {:error, Error.validation("Pi project_trust must be :default, :approve, or :deny", provider: :pi)}

  defp tool_args(%{sandbox_mode: :read_only, allowed_tools: nil}),
    do: {:ok, list_pair("--tools", @read_only_tools)}

  defp tool_args(%{sandbox_mode: :read_only, allowed_tools: tools}) do
    if Enum.all?(tools, &(&1 in @read_only_tools)) do
      {:ok, list_pair("--tools", tools)}
    else
      {:error,
       Error.validation("Pi read-only sandbox accepts only read, grep, find, and ls tools",
         provider: :pi,
         details: %{field: :allowed_tools}
       )}
    end
  end

  defp tool_args(%{sandbox_mode: mode, allowed_tools: tools}) when mode in [:default, :unrestricted],
    do: {:ok, list_pair("--tools", tools)}

  defp tool_args(%{sandbox_mode: mode}),
    do: {:error, Error.validation("Pi cannot represent sandbox mode", provider: :pi, details: %{value: mode})}

  defp flag(flag, true), do: [flag]
  defp flag(_flag, _value), do: []
  defp pair(_flag, nil), do: []
  defp pair(flag, value), do: [flag, to_string(value)]
  defp list_pair(_flag, nil), do: []
  defp list_pair(flag, values), do: [flag, Enum.join(values, ",")]
  defp repeat(flag, values), do: Enum.flat_map(values, &pair(flag, &1))

  defp string_list(nil, _field), do: {:ok, []}

  defp string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: string_list(:invalid, field)
  end

  defp string_list(_values, field),
    do: {:error, Error.validation("Pi #{field} must be a list of strings", provider: :pi)}

  defp extra_args(nil), do: {:ok, []}

  defp extra_args(args) when is_list(args) do
    cond do
      not Enum.all?(args, &is_binary/1) ->
        extra_args(:invalid)

      shadow = Enum.find(args, &reserved_arg?/1) ->
        {:error,
         Error.validation("Pi extra_args cannot shadow managed options",
           provider: :pi,
           details: %{argument: shadow}
         )}

      true ->
        {:ok, args}
    end
  end

  defp extra_args(_args),
    do: {:error, Error.validation("Pi extra_args must be a list of strings", provider: :pi)}

  defp reserved_arg?(argument) do
    argument in @reserved_args or Enum.any?(@reserved_args, &String.starts_with?(argument, &1 <> "="))
  end

  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(value) when is_number(value), do: "number"
  defp value_type(_value), do: "other"
end
