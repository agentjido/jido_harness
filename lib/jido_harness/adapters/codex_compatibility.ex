defmodule Jido.Harness.Adapters.CodexCompatibility do
  @moduledoc false

  alias Jido.Harness.{Error, ProcessEvent, ProcessInfo, ProcessManager}
  alias Jido.Harness.Adapters.CodexEnvironment

  @minimum_version Version.parse!("0.144.6")
  @required_exec_flags ~w(--output-schema --ephemeral --ignore-user-config --ignore-rules)

  @doc false
  @spec validate(String.t(), map()) :: :ok | {:error, Error.t()}
  def validate(executable, context) do
    manager = Map.get(context, :process_manager, ProcessManager)

    with {:ok, version_output} <- probe(manager, executable, ["--version"]),
         {:ok, version} <- parse_version(version_output),
         :ok <- minimum_version(version),
         {:ok, help_output} <- probe(manager, executable, ["exec", "--help"]),
         :ok <- required_flags(help_output) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      _error -> incompatible()
    end
  end

  @doc false
  @spec subscription_authenticated?(String.t(), map()) :: boolean()
  def subscription_authenticated?(executable, context \\ %{}) do
    manager = Map.get(context, :process_manager, ProcessManager)
    match?({:ok, _output}, probe(manager, executable, ["login", "status"]))
  end

  defp probe(manager, executable, argv) do
    spec = %{
      executable: executable,
      argv: argv,
      stdin: false,
      env: CodexEnvironment.cached_subscription(),
      env_mode: :replace,
      runtime_timeout_ms: 15_000,
      idle_timeout_ms: 15_000,
      metadata: %{provider: :codex, operation: :compatibility_probe}
    }

    case manager.start_owned_process(spec, self()) do
      {:ok, id} ->
        try do
          with {:ok, %ProcessInfo{state: :exited}} <- manager.await_process(id, 20_000),
               {:ok, events} <- manager.replay_process(id, cursor: 0, limit: 1_000) do
            {:ok,
             events
             |> Enum.filter(&match?(%ProcessEvent{type: type} when type in [:stdout, :stderr], &1))
             |> Enum.map_join("", &to_string(&1.data))}
          else
            _error -> incompatible()
          end
        after
          _ = manager.prune_process(id)
        end

      _error ->
        incompatible()
    end
  end

  defp parse_version(output) do
    case Regex.run(~r/\b(\d+\.\d+\.\d+)\b/, output, capture: :all_but_first) do
      [version] -> Version.parse(version)
      _match -> incompatible()
    end
  end

  defp minimum_version(version) do
    if Version.compare(version, @minimum_version) in [:eq, :gt], do: :ok, else: incompatible()
  end

  defp required_flags(output) do
    if Enum.all?(@required_exec_flags, &String.contains?(output, &1)), do: :ok, else: incompatible()
  end

  defp incompatible,
    do:
      {:error,
       Error.new(:configuration, "Codex CLI is incompatible with structured output",
         provider: :codex,
         details: %{failure_kind: :incompatible_cli, minimum_version: to_string(@minimum_version)}
       )}
end
