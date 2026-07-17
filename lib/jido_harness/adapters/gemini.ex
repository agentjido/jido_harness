defmodule Jido.Harness.Adapters.Gemini do
  @moduledoc "Gemini CLI SDK-backed harness adapter."
  @behaviour Jido.Harness.Adapter

  alias GeminiCliSdk.Options
  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Adapters.SDKMapper, Capabilities, Error, RunRequest}

  @provider_options [:extensions, :allowed_mcp_server_names, :debug, :settings, :max_stderr_buffer_bytes]

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
        usage?: true
      },
      default_session_transport: :sdk,
      session_transports: [
        %Jido.Harness.SessionTransportSpec{
          name: :sdk,
          adapter: Jido.Harness.SessionAdapters.SDKRuntime,
          capabilities: %Jido.Harness.InteractionCapabilities{
            transport: :sdk,
            process: :persistent,
            multi_turn: :native,
            follow_up: :managed,
            interrupt: :native
          },
          session_options: [
            :model,
            :provider_session_id,
            :system_prompt,
            :allowed_tools,
            :add_dirs,
            :approval_mode,
            :sandbox_mode,
            :env
          ],
          session_provider_options: :adapter
        }
      ],
      normalized_options: [
        :model,
        :provider_session_id,
        :system_prompt,
        :allowed_tools,
        :add_dirs,
        :approval_mode,
        :sandbox_mode
      ],
      normalized_values: %{sandbox_mode: [:default, :workspace_write, :unrestricted]},
      provider_options: @provider_options,
      install: %{npm: "@google/gemini-cli"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    with :ok <- validate_sandbox(request.sandbox_mode) do
      do_run(request, context)
    end
  end

  defp do_run(request, context) do
    provider = Helpers.provider_options(request.provider_options, @provider_options)

    attrs =
      provider
      |> Map.merge(%{
        model: request.model,
        approval_mode: approval_mode(request.approval_mode),
        sandbox: request.sandbox_mode in [:read_only, :workspace_write],
        include_directories: request.add_dirs || [],
        allowed_tools: request.allowed_tools || [],
        output_format: "stream-json",
        cwd: request.cwd,
        env: Map.merge(Map.get(context.config, :env, %{}), request.env),
        system_prompt: request.system_prompt,
        timeout_ms: Helpers.sdk_timeout(request.runtime_timeout_ms)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    options = struct(Options, attrs) |> Options.validate!()
    sdk = Map.get(context.config, :sdk_module, GeminiCliSdk)

    source =
      if request.provider_session_id do
        session_module = Map.get(context.config, :session_module, GeminiCliSdk.Session)
        session_module.resume(request.provider_session_id, options, request.prompt)
      else
        sdk.execute(request.prompt, options)
      end

    stream =
      Stream.transform(source, nil, fn event, sid ->
        current = Map.get(event, :session_id) || sid
        {SDKMapper.gemini(event, current), current}
      end)

    {:ok, stream}
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

  defp approval_mode(:default), do: nil
  defp approval_mode(:prompt), do: :default
  defp approval_mode(:auto_edit), do: :auto_edit
  defp approval_mode(:auto_approve), do: :yolo
  defp validate_sandbox(mode) when mode in [:default, :workspace_write, :unrestricted], do: :ok

  defp validate_sandbox(:read_only),
    do:
      {:error,
       Error.validation("Gemini SDK cannot guarantee the :read_only sandbox mode",
         provider: :gemini,
         details: %{field: :sandbox_mode}
       )}
end
