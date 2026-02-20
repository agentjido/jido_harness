defmodule Jido.Harness.Exec.Workspace do
  @moduledoc """
  Workspace lifecycle helpers backed by `Jido.Shell.SpriteLifecycle`.
  """

  alias Jido.Harness.Exec.Error
  alias Jido.Shell.SpriteLifecycle

  @doc """
  Provisions a sprite-backed workspace/session for harness execution.
  """
  @spec provision_workspace(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def provision_workspace(workspace_id, opts \\ [])
      when is_binary(workspace_id) and is_list(opts) do
    sprite_config = Keyword.get(opts, :sprite_config, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)
    workspace_dir = Keyword.get(opts, :workspace_dir)
    sprite_name = Keyword.get(opts, :sprite_name)
    session_mod = Keyword.get(opts, :session_mod, Jido.Shell.ShellSession)
    agent_mod = Keyword.get(opts, :agent_mod, Jido.Shell.Agent)

    if map_size(sprite_config) == 0 do
      {:error, Error.invalid("sprite_config is required for workspace provisioning", %{field: :sprite_config})}
    else
      SpriteLifecycle.provision(workspace_id, sprite_config,
        timeout: timeout,
        workspace_dir: workspace_dir,
        sprite_name: sprite_name,
        session_mod: session_mod,
        agent_mod: agent_mod
      )
    end
  end

  @doc """
  Tears down a provisioned sprite/session and returns teardown metadata.
  """
  @spec teardown_workspace(String.t(), keyword()) :: map()
  def teardown_workspace(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    SpriteLifecycle.teardown(session_id, opts)
  end
end
