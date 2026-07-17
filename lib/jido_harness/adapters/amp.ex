defmodule Jido.Harness.Adapters.Amp do
  @moduledoc "Amp CLI adapter using execute-mode stream JSON."
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.CLIArgs, Adapters.CLIMapper, Adapters.CLIStream}
  alias Jido.Harness.{Adapters.Helpers, Capabilities, Error, RunRequest}

  @provider_options [
    :cli_path,
    :mode,
    :dangerously_allow_all,
    :visibility,
    :settings_file,
    :log_level,
    :log_file,
    :toolbox,
    :labels,
    :no_ide,
    :no_notifications,
    :no_color,
    :no_jetbrains
  ]

  @impl true
  def spec do
    %AdapterSpec{
      provider: :amp,
      name: "Amp",
      executable: "amp",
      docs_url: "https://ampcode.com/manual",
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
      normalized_options: [:provider_session_id, :mcp_config, :reasoning_effort],
      provider_options: @provider_options,
      install: %{npm: "@sourcegraph/amp"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    options = Helpers.provider_options(request.provider_options, @provider_options)

    with :ok <- validate_options(options),
         {:ok, argv} <- build_argv(request, options) do
      env = Helpers.merge_env(request, context.config, toolbox_env(options[:toolbox]))
      request = %{request | env: env}
      executable = options[:cli_path] || Helpers.cli_path(context.config, spec().executable)
      CLIStream.run(:amp, request, context, executable, argv, &CLIMapper.amp/1)
    end
  rescue
    exception ->
      {:error,
       Error.validation("invalid Amp options", provider: :amp, details: %{message: Exception.message(exception)})}
  end

  @impl true
  def status(config),
    do:
      Helpers.status(:amp, spec().executable, ["AMP_API_KEY"], config,
        cli_path_env: "AMP_CLI_PATH",
        capabilities: spec().capabilities
      )

  @impl true
  def install(_config, options), do: Helpers.install_npm(:amp, "@sourcegraph/amp", options)

  @impl true
  def cancel(run_id, _context), do: Helpers.cancel_cli_run(run_id)

  @doc false
  def build_argv(request, options) do
    output = if request.reasoning_effort, do: "--stream-json-thinking", else: "--stream-json"

    argv =
      resume_args(request.provider_session_id) ++
        ["--execute", request.prompt, output] ++
        CLIArgs.flag("--dangerously-allow-all", options[:dangerously_allow_all]) ++
        CLIArgs.pair("--visibility", options[:visibility]) ++
        CLIArgs.pair("--settings-file", options[:settings_file]) ++
        CLIArgs.pair("--log-level", options[:log_level]) ++
        CLIArgs.pair("--log-file", options[:log_file]) ++
        CLIArgs.pair("--mode", options[:mode]) ++
        CLIArgs.json_pair("--mcp-config", request.mcp_config) ++
        CLIArgs.repeat("--label", options[:labels]) ++
        CLIArgs.flag("--no-ide", options[:no_ide]) ++
        CLIArgs.flag("--no-notifications", options[:no_notifications]) ++
        CLIArgs.flag("--no-color", options[:no_color]) ++
        CLIArgs.flag("--no-jetbrains", options[:no_jetbrains])

    {:ok, argv}
  end

  defp validate_options(options) do
    cond do
      not optional_string?(options[:cli_path]) ->
        invalid(:cli_path, "a string")

      not optional_string?(options[:mode]) ->
        invalid(:mode, "a string")

      not optional_string?(options[:visibility]) ->
        invalid(:visibility, "a string")

      not optional_string?(options[:settings_file]) ->
        invalid(:settings_file, "a string")

      not optional_string?(options[:log_level]) ->
        invalid(:log_level, "a string")

      not optional_string?(options[:log_file]) ->
        invalid(:log_file, "a string")

      not optional_string?(options[:toolbox]) ->
        invalid(:toolbox, "a string")

      not optional_string_list?(options[:labels]) ->
        invalid(:labels, "a list of strings")

      invalid_boolean =
          Enum.find(
            [:dangerously_allow_all, :no_ide, :no_notifications, :no_color, :no_jetbrains],
            &(not optional_boolean?(options[&1]))
          ) ->
        invalid(invalid_boolean, "a boolean")

      true ->
        :ok
    end
  end

  defp resume_args(nil), do: []
  defp resume_args(id), do: ["threads", "continue", id]
  defp toolbox_env(nil), do: %{}
  defp toolbox_env(value), do: %{"AMP_TOOLBOX" => value}
  defp optional_string?(value), do: is_nil(value) or is_binary(value)
  defp optional_string_list?(value), do: is_nil(value) or (is_list(value) and Enum.all?(value, &is_binary/1))
  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)
  defp invalid(field, expected), do: {:error, Error.validation("Amp #{field} must be #{expected}", provider: :amp)}
end
