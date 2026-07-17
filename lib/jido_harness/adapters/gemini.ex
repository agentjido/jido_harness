defmodule Jido.Harness.Adapters.Gemini do
  @moduledoc "Gemini CLI adapter using headless stream JSON."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.CLIArgs, Adapters.CLIMapper, Adapters.CLIStream}
  alias Jido.Harness.{Adapters.Helpers, Capabilities, Error, RunRequest}

  @provider_options [:cli_path, :extensions, :allowed_mcp_server_names, :debug]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :gemini,
      name: "Gemini CLI",
      executable: "gemini",
      docs_url: "https://github.com/google-gemini/gemini-cli",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        resume?: true,
        usage?: true,
        native_cancel?: true
      },
      default_session_transport: :stream_json_resume,
      session_transports: [Jido.Harness.SessionTransportSpec.managed(:stream_json_resume)],
      normalized_options: [
        :model,
        :provider_session_id,
        :system_prompt,
        :allowed_tools,
        :add_dirs,
        :approval_mode,
        :sandbox_mode
      ],
      normalized_values: %{sandbox_mode: [:default, :read_only, :workspace_write, :unrestricted]},
      provider_options: @provider_options,
      install: %{npm: "@google/gemini-cli"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(request, options),
         {:ok, argv} <- build_argv(request, options) do
      additions = if request.system_prompt, do: %{"GEMINI_SYSTEM_MD" => request.system_prompt}, else: %{}
      request = %{request | env: Helpers.merge_env(request, context.config, additions)}
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      mapper = fn event, session_id -> CLIMapper.gemini(event, session_id) end
      CLIStream.run(:gemini, request, context, executable, argv, mapper, request.provider_session_id)
    end
  rescue
    exception ->
      {:error,
       Error.validation("invalid Gemini options", provider: :gemini, details: %{message: Exception.message(exception)})}
  end

  @impl true
  def status(config),
    do:
      Helpers.status(
        :gemini,
        spec().executable,
        ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA"],
        config,
        cli_path_env: "GEMINI_CLI_PATH",
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:gemini, "@google/gemini-cli", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options) do
    argv =
      ["--prompt", request.prompt, "--output-format", "stream-json"] ++
        CLIArgs.pair("--model", request.model) ++
        approval_args(request) ++
        sandbox_args(request.sandbox_mode) ++
        CLIArgs.pair("--resume", request.provider_session_id) ++
        CLIArgs.repeat("--extensions", options[:extensions]) ++
        CLIArgs.comma_pair("--include-directories", request.add_dirs) ++
        CLIArgs.comma_pair("--allowed-tools", request.allowed_tools) ++
        CLIArgs.comma_pair("--allowed-mcp-server-names", options[:allowed_mcp_server_names]) ++
        CLIArgs.flag("--debug", options[:debug])

    {:ok, argv}
  end

  defp validate_options(%{sandbox_mode: :read_only, approval_mode: mode}, _options)
       when mode not in [:default, :prompt],
       do:
         {:error,
          Error.validation("Gemini read-only mode cannot be combined with automatic approval",
            provider: :gemini,
            details: %{field: :approval_mode}
          )}

  defp validate_options(_request, options) do
    cond do
      not optional_string?(options[:cli_path]) ->
        invalid(:cli_path, "a string")

      not optional_string_list?(options[:extensions]) ->
        invalid(:extensions, "a list of strings")

      not optional_string_list?(options[:allowed_mcp_server_names]) ->
        invalid(:allowed_mcp_server_names, "a list of strings")

      not optional_boolean?(options[:debug]) ->
        invalid(:debug, "a boolean")

      true ->
        :ok
    end
  end

  defp approval_args(%{sandbox_mode: :read_only}), do: ["--approval-mode", "plan"]
  defp approval_args(%{approval_mode: :default}), do: []
  defp approval_args(%{approval_mode: :prompt}), do: ["--approval-mode", "default"]
  defp approval_args(%{approval_mode: :auto_edit}), do: ["--approval-mode", "auto_edit"]
  defp approval_args(%{approval_mode: :auto_approve}), do: ["--approval-mode", "yolo"]
  defp sandbox_args(:workspace_write), do: ["--sandbox"]
  defp sandbox_args(_mode), do: []
  defp optional_string?(value), do: is_nil(value) or is_binary(value)
  defp optional_string_list?(value), do: is_nil(value) or (is_list(value) and Enum.all?(value, &is_binary/1))
  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)

  defp invalid(field, expected),
    do: {:error, Error.validation("Gemini #{field} must be #{expected}", provider: :gemini)}
end
