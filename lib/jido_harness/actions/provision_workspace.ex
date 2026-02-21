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
  alias Jido.Harness.Exec.Error
  alias Jido.Harness.Exec.Workspace

  @impl true
  def run(params, _context) do
    with {:ok, opts} <- Helpers.to_keyword(params.opts || %{}) do
      Workspace.provision_workspace(params.workspace_id, opts)
    else
      {:error, {:invalid_option_key, key}} ->
        {:error, Error.invalid("Unsupported option key for provision workspace", %{field: :opts, key: key})}

      {:error, :invalid_options} ->
        {:error, Error.invalid("opts must be a map or keyword list", %{field: :opts})}
    end
  end
end
