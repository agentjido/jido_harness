defmodule Jido.Harness.Actions.TeardownWorkspace do
  @moduledoc "Tear down a workspace/session for harness runtime execution."

  use Jido.Action,
    name: "harness_teardown_workspace",
    description: "Teardown harness workspace",
    schema: [
      session_id: [type: :string, required: true],
      opts: [type: :map, default: %{}]
    ]

  alias Jido.Harness.Actions.Helpers
  alias Jido.Harness.Exec.Workspace

  @impl true
  def run(params, _context) do
    Helpers.with_keyword_opts(params.opts, "Unsupported option key for workspace teardown", fn opts ->
      {:ok, Workspace.teardown_workspace(params.session_id, opts)}
    end)
  end
end
