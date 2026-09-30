defmodule Jido.Harness.Adapters.Antigravity do
  @moduledoc """
  Google Antigravity CLI provider profile using the refined Antigravity ACP adapter.

  The `agy` CLI ships no ACP mode of its own, so this profile launches the
  `refined-antigravity-acp` adapter. The adapter drives Google's ACP server and
  translates it into ACP messages, which makes it the source of `Event.raw`.

  Provision the adapter once with `refined-antigravity-acp setup`, which also
  accepts the Google Antigravity Terms of Service.

  The ACP server authenticates separately from the `agy` CLI through its own
  `~/.gemini/antigravity-acp/settings.json`, so a CLI login does not carry over.
  No ACP `authenticate` method is declared, because the server's OAuth method
  opens a browser flow that cannot complete inside a harness run. See
  `guides/providers.md` for the required one-time setup.
  """
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Adapters.Helpers, Capabilities, Error, ProviderStatus}
  alias Jido.Harness.Adapters.Antigravity.Authentication

  @install_url "https://antigravity.google/cli/install.sh"

  @impl true
  def spec do
    %AdapterSpec{
      provider: :antigravity,
      name: "Antigravity CLI",
      executable: "agy",
      docs_url: "https://antigravity.google/docs/cli/install/",
      capabilities: %Capabilities{
        streaming?: true,
        tool_calls?: true,
        tool_results?: true,
        thinking?: true,
        resume?: true,
        usage?: true,
        native_cancel?: true
      },
      acp_agent:
        Jido.Harness.ACPAgentSpec.adapter(
          "refined-antigravity-acp",
          "@simonepri/refined-antigravity-acp@1.2.11",
          %{
            maturity: :experimental,
            capabilities: %{
              load_session: true,
              multimodal: true,
              dynamic_model: true,
              dynamic_configuration: true,
              usage: true
            },
            turn_options: [:attachments, :content],
            configuration_options: [:model, :reasoning_effort]
          }
        ),
      normalized_options: [:model, :provider_session_id, :mcp_config, :attachments, :reasoning_effort],
      normalized_values: %{reasoning_effort: [nil, :low, :medium, :high]},
      install: %{script: @install_url}
    }
  end

  @impl true
  def status(config) do
    with {:ok, status} <-
           Helpers.status(:antigravity, spec().executable, [], config,
             cli_path_env: "ANTIGRAVITY_CLI_PATH",
             capabilities: spec().capabilities
           ) do
      {authenticated, error} = Authentication.check(config)
      {:ok, ProviderStatus.finalize(%{status | authenticated: authenticated, error: status.error || error})}
    end
  end

  @impl true
  def acp_env(request, config) do
    env = Authentication.environment(request.env_mode, config, request.env)
    options = if is_binary(env["NODE_OPTIONS"]), do: env["NODE_OPTIONS"], else: ""
    path = :jido_harness |> :code.priv_dir() |> to_string() |> Path.join("acp/antigravity.mjs")

    case :erl_prim_loader.get_file(String.to_charlist(path)) do
      {:ok, source, _path} ->
        uri = "data:text/javascript;base64," <> Base.encode64(source)
        {:ok, %{"NODE_OPTIONS" => String.trim(options <> " --import=" <> uri)}}

      :error ->
        {:error, Error.new(:configuration, "Antigravity ACP crash guard is missing", provider: :antigravity)}
    end
  end

  @impl true
  def install(_config, options), do: Helpers.install_script(:antigravity, @install_url, options)
end
