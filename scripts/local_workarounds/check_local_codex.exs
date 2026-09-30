alias Jido.Harness.Process, as: NativeProcess

root = Path.expand("../..", __DIR__)
state = Path.join(root, ".local-workarounds")
File.mkdir_p!(state)
fixture = Path.join(System.tmp_dir!(), "harness-local-codex-#{System.unique_integer([:positive])}")
File.mkdir_p!(fixture)
{_, 0} = System.cmd("git", ["init", "--quiet", fixture])

File.write!(
  Path.join(fixture, "AGENTS.md"),
  "Create workspace-instructions.txt with the text workspace instructions applied.\n"
)

helper = Path.join(__DIR__, "codex_isolated.py")

prompt =
  "Create proof.txt with the exact text isolation works. Follow workspace instructions. Read only this workspace."

{:ok, process_id} =
  NativeProcess.start(%{
    executable: System.find_executable("python3"),
    argv: [helper, "--cwd", fixture, "--effort", "low", "--", prompt],
    cwd: fixture,
    runtime_timeout_ms: 120_000,
    idle_timeout_ms: 60_000
  })

{:ok, info} = NativeProcess.await(process_id, 130_000)
{:ok, events} = NativeProcess.replay(process_id, limit: 10_000)
stdout = events |> Enum.filter(&(&1.type == :stdout)) |> Enum.map(& &1.data) |> IO.iodata_to_binary()
File.write!(Path.join(state, "codex-managed-live.jsonl"), stdout)

thread_id =
  stdout
  |> String.split("\n", trim: true)
  |> Enum.find_value(fn line ->
    case Jason.decode(line) do
      {:ok, %{"type" => "thread.started", "thread_id" => id}} -> id
      _ -> nil
    end
  end)

sessions = Path.join(System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"), "sessions")
persisted = if thread_id, do: Path.wildcard(Path.join(sessions, "**/*#{thread_id}*")), else: []

read = fn name ->
  case File.read(Path.join(fixture, name)) do
    {:ok, value} -> String.trim(value)
    {:error, _reason} -> nil
  end
end

record = %{
  status: info.state,
  process_id: process_id,
  exit_status: info.exit_status,
  fixture: fixture,
  model: "CLI default",
  helper_sha256: helper |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
  thread_id: thread_id,
  persisted_session_files: length(persisted),
  proof: read.("proof.txt"),
  instructions: read.("workspace-instructions.txt")
}

File.write!(Path.join(state, "codex-managed-live-check.json"), Jason.encode!(record, pretty: true) <> "\n")
IO.inspect(record, label: "local Codex check")

if info.state != :exited or record.proof != "isolation works" or
     record.instructions != "workspace instructions applied" or is_nil(thread_id) or persisted != [] do
  IO.puts(:stderr, "The live check failed. See .local-workarounds/codex-managed-live.jsonl and process replay.")
  System.halt(1)
end

:ok = NativeProcess.prune(process_id)
