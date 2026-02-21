defmodule Jido.Harness.Signal.WorkspaceProvisioned do
  @moduledoc """
  Signal emitted when a harness workspace is successfully provisioned.
  """

  use Jido.Signal,
    type: "jido.harness.workspace.provisioned",
    default_source: "/jido/harness/workspace",
    schema: [
      run_id: [type: :string, required: false],
      request_id: [type: :string, required: false],
      workspace_id: [type: :string, required: false],
      session_id: [type: :string, required: false],
      provider: [type: :atom, required: false]
    ]
end
