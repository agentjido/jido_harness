defmodule Jido.Harness.Exec.Workspace do
  @moduledoc """
  Workspace lifecycle helpers with pluggable environment backends.

  By default, workspace lifecycle operations use `Jido.Shell.Environment.Sprite`.
  Pass `environment: MyEnvironment` in opts to use a different provider.
  """

  alias Jido.Harness.Exec.Error

  @default_environment Jido.Shell.Environment.Sprite

  @doc """
  Provisions a workspace/session for harness execution.

  ## Options

  - `:environment` - module implementing `Jido.Shell.Environment`
  - `:config` - environment-specific configuration map
  - `:sprite_config` - legacy alias for Sprite configuration
  - all other options are passed through to the environment's `provision/3`
  """
  @spec provision_workspace(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def provision_workspace(workspace_id, opts \\ [])
      when is_binary(workspace_id) and is_list(opts) do
    environment = Keyword.get(opts, :environment, @default_environment)
    config = Keyword.get(opts, :sprite_config, Keyword.get(opts, :config, %{}))

    if map_size(config) == 0 do
      {:error, Error.invalid("config is required for workspace provisioning", %{field: :config})}
    else
      environment.provision(workspace_id, config, opts)
    end
  end

  @doc """
  Tears down a provisioned workspace/session and returns teardown metadata.

  ## Options

  - `:environment` - module implementing `Jido.Shell.Environment`
  - all other options are passed through to the environment's `teardown/2`
  """
  @spec teardown_workspace(String.t(), keyword()) :: map()
  def teardown_workspace(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    environment = Keyword.get(opts, :environment, @default_environment)
    environment.teardown(session_id, opts)
  end
end
