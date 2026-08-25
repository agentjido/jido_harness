defmodule Jido.Harness.TestAdapter do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities, ProviderStatus}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :test,
      name: "Test fixture",
      executable: "fixture",
      acp_agent:
        Jido.Harness.ACPAgentSpec.native("fixture-acp", [], %{
          capabilities: %{load_session: true, dynamic_model: true},
          configuration_options: [:model],
          session_provider_options: :adapter,
          session_options: [:provider_session_id, :mcp_config, :approval_mode]
        }),
      capabilities: %Capabilities{streaming?: true, resume?: true},
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
        :attachments,
        :reasoning_effort
      ],
      provider_options: [:fixture_mode]
    }
  end

  @impl true
  def status(_config) do
    {:ok,
     %ProviderStatus{
       provider: :test,
       installed: true,
       compatible: true,
       authenticated: true,
       smoke_ready: true,
       capabilities: spec().capabilities,
       executable: "fixture"
     }}
  end
end

defmodule Jido.Harness.OwnedCLITestAdapter do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :owned_cli,
      name: "Owned CLI test fixture",
      executable: "/bin/sleep",
      acp_agent: Jido.Harness.ACPAgentSpec.native("fixture-acp", []),
      capabilities: %Capabilities{streaming?: true, native_cancel?: true},
      normalized_options: [],
      provider_options: []
    }
  end

  @impl true
  defdelegate status(config), to: Jido.Harness.TestAdapter
end

defmodule Jido.Harness.LimitedTestAdapter do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :limited,
      name: "Limited test fixture",
      executable: "fixture",
      acp_agent: Jido.Harness.ACPAgentSpec.native("fixture-acp", []),
      capabilities: %Capabilities{},
      normalized_options: [],
      provider_options: []
    }
  end

  @impl true
  defdelegate status(config), to: Jido.Harness.TestAdapter
end
