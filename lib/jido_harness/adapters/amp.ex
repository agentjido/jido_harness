defmodule Jido.Harness.Adapters.Amp do
  @moduledoc "Amp SDK-backed harness adapter."
  @behaviour Jido.Harness.Adapter

  alias AmpSdk.Types.Options
  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Adapters.SDKMapper, Capabilities, Error, RunRequest}

  @provider_options [
    :mode,
    :dangerously_allow_all,
    :visibility,
    :settings_file,
    :log_level,
    :log_file,
    :toolbox,
    :skills,
    :permissions,
    :labels,
    :thinking,
    :max_stderr_buffer_bytes,
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
            steer: :native,
            interrupt: :native
          },
          session_options: [:model, :provider_session_id, :mcp_config, :reasoning_effort, :env],
          session_provider_options: :adapter
        }
      ],
      normalized_options: [:model, :provider_session_id, :mcp_config, :reasoning_effort],
      provider_options: @provider_options,
      install: %{npm: "@sourcegraph/amp"}
    }
  end

  @impl true
  def run(%RunRequest{} = request, context) do
    provider = Helpers.provider_options(request.provider_options, @provider_options)

    attrs =
      provider
      |> Map.put(:cwd, request.cwd)
      |> Map.put(:env, Map.merge(Map.get(context.config, :env, %{}), request.env))
      |> Map.put(:continue_thread, request.provider_session_id)
      |> Map.put(:mcp_config, request.mcp_config)
      |> Map.put(:model_payload, request.model)
      |> put_reasoning(request.reasoning_effort)
      |> Map.put(:stream_timeout_ms, Helpers.sdk_timeout(request.runtime_timeout_ms))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    options = struct(Options, attrs) |> Options.validate!()
    sdk = Map.get(context.config, :sdk_module, AmpSdk)
    {:ok, sdk.execute(request.prompt, options) |> Stream.flat_map(&SDKMapper.amp/1)}
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

  defp put_reasoning(options, nil), do: options
  defp put_reasoning(options, _effort), do: Map.put(options, :thinking, true)
end
