defmodule Jido.Harness.Actions.ProvisionWorkspace do
  @moduledoc "Provision a workspace/session for harness runtime execution."

  use Jido.Action,
    name: "harness_provision_workspace",
    description: "Provision harness workspace",
    schema: [
      workspace_id: [type: :string, required: true],
      opts: [type: :map, default: %{}]
    ]

  alias Jido.Harness.Actions.Helpers
  alias Jido.Harness.Exec.Workspace

  @impl true
  def run(params, _context) do
    Helpers.with_keyword_opts(params.opts, "Unsupported option key for provision workspace", fn opts ->
      Workspace.provision_workspace(params.workspace_id, opts)
    end)
  end
end
