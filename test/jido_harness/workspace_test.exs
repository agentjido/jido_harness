defmodule Jido.Harness.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Actions.{ProvisionWorkspace, TeardownWorkspace}
  alias Jido.Harness.Exec.Workspace

  defmodule EnvironmentStub do
    @behaviour Jido.Shell.Environment

    @impl true
    def provision(workspace_id, config, opts) do
      {:ok,
       %{
         workspace_id: workspace_id,
         session_id: "session-#{workspace_id}",
         workspace_dir: Map.get(config, :workspace_dir, "/work/#{workspace_id}"),
         config: config,
         opts: opts
       }}
    end

    @impl true
    def teardown(session_id, opts) do
      %{
        teardown_verified: true,
        teardown_attempts: 1,
        warnings: nil,
        session_id: session_id,
        opts: opts
      }
    end
  end

  describe "provision_workspace/2" do
    test "uses a custom environment backend" do
      assert {:ok, result} =
               Workspace.provision_workspace("workspace-1",
                 environment: EnvironmentStub,
                 config: %{workspace_dir: "/tmp/workspace-1"},
                 marker: :kept
               )

      assert result.session_id == "session-workspace-1"
      assert result.workspace_dir == "/tmp/workspace-1"
      assert result.config == %{workspace_dir: "/tmp/workspace-1"}
      assert result.opts[:environment] == EnvironmentStub
      assert result.opts[:marker] == :kept
    end

    test "accepts sprite_config as the legacy config option" do
      assert {:ok, result} =
               Workspace.provision_workspace("workspace-2",
                 environment: EnvironmentStub,
                 sprite_config: %{workspace_dir: "/tmp/workspace-2"}
               )

      assert result.config == %{workspace_dir: "/tmp/workspace-2"}
    end

    test "returns a harness error when config is missing" do
      assert {:error, error} =
               Workspace.provision_workspace("workspace-3", environment: EnvironmentStub)

      assert error.field == :config
      assert Exception.message(error) == "config is required for workspace provisioning"
    end
  end

  describe "teardown_workspace/2" do
    test "uses a custom environment backend" do
      result = Workspace.teardown_workspace("session-1", environment: EnvironmentStub, marker: :kept)

      assert result.teardown_verified
      assert result.session_id == "session-1"
      assert result.opts[:environment] == EnvironmentStub
      assert result.opts[:marker] == :kept
    end
  end

  describe "workspace actions" do
    test "provision action forwards top-level environment into opts" do
      assert {:ok, result} =
               ProvisionWorkspace.run(
                 %{
                   workspace_id: "workspace-4",
                   environment: EnvironmentStub,
                   opts: %{config: %{workspace_dir: "/tmp/workspace-4"}}
                 },
                 %{}
               )

      assert result.opts[:environment] == EnvironmentStub
      assert result.config == %{workspace_dir: "/tmp/workspace-4"}
    end

    test "teardown action forwards top-level environment into opts" do
      assert {:ok, result} =
               TeardownWorkspace.run(
                 %{session_id: "session-2", environment: EnvironmentStub, opts: %{}},
                 %{}
               )

      assert result.teardown_verified
      assert result.opts[:environment] == EnvironmentStub
    end
  end
end
