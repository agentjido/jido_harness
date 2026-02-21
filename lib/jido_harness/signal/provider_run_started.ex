defmodule Jido.Harness.Signal.ProviderRunStarted do
  @moduledoc """
  Signal emitted when provider stream execution begins.
  """

  use Jido.Signal,
    type: "jido.harness.provider.run.started",
    default_source: "/jido/harness/provider",
    schema: [
      run_id: [type: :string, required: false],
      request_id: [type: :string, required: false],
      session_id: [type: :string, required: false],
      provider: [type: :atom, required: false],
      cwd: [type: :string, required: false],
      command: [type: :string, required: false]
    ]
end
