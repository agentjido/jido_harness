defmodule HarnessAgentExample.Record do
  @moduledoc "Records recent Harness results and denies permission requests in the sample Agent."

  use Jido.Action, name: "record_harness_result", schema: Jido.Joi.map()

  alias Jido.Agent.Directive
  alias Jido.Harness.Plugin.Command

  @impl true
  def run(_params, %{signal: signal, agent_state: state}) do
    entry = %{"type" => signal.type, "data" => signal.data}
    state = %{state | events: Enum.take([entry | state.events], 64)}

    case signal.type do
      "jido.harness.approval.requested" ->
        id = signal.data["approval_id"]
        {:ok, state, [Directive.emit(Command.respond_approval("deny-" <> id, id, :deny))]}

      _ ->
        {:ok, state}
    end
  end
end

defmodule HarnessAgentExample.Wrapper do
  @moduledoc "Defines the common routes for the sample coding Agents."

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote do
      use Jido.Agent,
        name: unquote("harness_" <> Atom.to_string(provider)),
        plugins: [Jido.Harness.Plugin]

      state do
        schema(Jido.Joi.object(%{events: Jido.Joi.array(Jido.Joi.map()) |> Jido.Joi.default([])}))
      end

      harness do
        provider(unquote(provider))
        cwd(env("HARNESS_AGENT_EXAMPLE_CWD"))
        turn_runtime_timeout_ms(90_000)
        approval_timeout_ms(5_000)
      end

      routes do
        route("jido.harness.command.*", Jido.Harness.Plugin.Execute)
        route("jido.harness.turn.*", HarnessAgentExample.Record)
        route("jido.harness.error.command", HarnessAgentExample.Record)
        route("jido.harness.approval.requested", HarnessAgentExample.Record)
      end
    end
  end
end

defmodule HarnessAgentExample.Codex do
  @moduledoc "A Jido Agent that wraps Codex."
  use HarnessAgentExample.Wrapper, provider: :codex
end

defmodule HarnessAgentExample.Claude do
  @moduledoc "A Jido Agent that wraps Claude Code."
  use HarnessAgentExample.Wrapper, provider: :claude
end

defmodule HarnessAgentExample.Amp do
  @moduledoc "A Jido Agent that wraps Amp."
  use HarnessAgentExample.Wrapper, provider: :amp
end
