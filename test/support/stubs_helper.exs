defmodule Jido.Harness.Test.RuntimeContractStub do
  @moduledoc false

  alias Jido.Harness.RuntimeContract

  @spec build(atom()) :: RuntimeContract.t()
  def build(provider) when is_atom(provider) do
    RuntimeContract.new!(%{
      provider: provider,
      host_env_required_any: [],
      host_env_required_all: [],
      sprite_env_forward: [],
      sprite_env_injected: %{},
      runtime_tools_required: [],
      compatibility_probes: [],
      install_steps: [],
      auth_bootstrap_steps: [],
      triage_command_template: "runtime --triage {{prompt}}",
      coding_command_template: "runtime --coding {{prompt}}",
      success_markers: []
    })
  end
end

defmodule Jido.Harness.Test.AdapterStub do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, Event, RunRequest}
  alias Jido.Harness.Test.RuntimeContractStub

  def id, do: :stub

  def capabilities do
    %Capabilities{
      streaming?: true,
      tool_calls?: true,
      cancellation?: true
    }
  end

  def run(%RunRequest{} = request, opts) do
    send(self(), {:adapter_stub_run, request, opts})

    {:ok,
     [
       Event.new!(%{
         type: :session_started,
         provider: :adapter_stub,
         session_id: "session-1",
         timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
         payload: %{"prompt" => request.prompt},
         raw: nil
       })
     ]}
  end

  def cancel(session_id) do
    send(self(), {:adapter_stub_cancel, session_id})
    :ok
  end

  def runtime_contract, do: RuntimeContractStub.build(:stub)
end

defmodule Jido.Harness.Test.PromptRunnerStub do
  @moduledoc false

  def run(prompt, opts) when is_binary(prompt) and is_list(opts) do
    send(self(), {:prompt_runner_run, prompt, opts})
    {:ok, "done: #{prompt}"}
  end
end

defmodule Jido.Harness.Test.StreamRunnerStub do
  @moduledoc false

  def run(prompt, opts) when is_binary(prompt) and is_list(opts) do
    send(self(), {:stream_runner_run, prompt, opts})

    {:ok,
     [
       %{"type" => "output_text_delta", "payload" => %{"text" => prompt}},
       %{"type" => "session_completed", "payload" => %{"status" => "ok"}}
     ]}
  end
end

defmodule Jido.Harness.Test.RunRequestRunnerStub do
  @moduledoc false

  alias Jido.Harness.{Event, RunRequest}

  def run_request(%RunRequest{} = request, opts) do
    send(self(), {:run_request_runner_run, request, opts})

    {:ok,
     [
       Event.new!(%{
         type: :session_completed,
         provider: :run_request_stub,
         session_id: "session-rq",
         timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
         payload: %{"prompt" => request.prompt},
         raw: nil
       })
     ]}
  end
end

defmodule Jido.Harness.Test.ExecuteRunnerStub do
  @moduledoc false

  def execute(prompt, opts) do
    send(self(), {:execute_runner_execute, prompt, opts})
    [%{event: "chunk", text: prompt}]
  end
end

defmodule Jido.Harness.Test.NoCancelStub do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, Event, RunRequest}
  alias Jido.Harness.Test.RuntimeContractStub

  def id, do: :no_cancel

  def capabilities do
    %Capabilities{
      streaming?: true,
      cancellation?: false
    }
  end

  def run(%RunRequest{} = request, _opts) do
    {:ok,
     [
       Event.new!(%{
         type: :session_completed,
         provider: :no_cancel,
         session_id: "session-no-cancel",
         timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
         payload: %{"prompt" => request.prompt},
         raw: nil
       })
     ]}
  end

  def runtime_contract, do: RuntimeContractStub.build(:no_cancel)
end

defmodule Jido.Harness.Test.AtomMapStreamRunnerStub do
  @moduledoc false

  def run(prompt, opts) when is_binary(prompt) and is_list(opts) do
    send(self(), {:atom_map_stream_runner_run, prompt, opts})
    {:ok, [%{type: :session_completed, payload: %{"status" => "ok"}}]}
  end
end

defmodule Jido.Harness.Test.UnsupportedRunnerStub do
  @moduledoc false

  def capabilities, do: %{}
end

defmodule Jido.Harness.Test.ErrorRunnerStub do
  @moduledoc false

  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, RunRequest}
  alias Jido.Harness.Test.RuntimeContractStub

  def id, do: :error_runner

  def capabilities do
    %Capabilities{
      streaming?: true,
      cancellation?: false
    }
  end

  def run(%RunRequest{}, _opts), do: {:error, :boom}

  def runtime_contract, do: RuntimeContractStub.build(:error_runner)
end

defmodule Jido.Harness.Test.InvalidEventRunnerStub do
  @moduledoc false

  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, RunRequest}
  alias Jido.Harness.Test.RuntimeContractStub

  def id, do: :invalid_events

  def capabilities do
    %Capabilities{
      streaming?: true,
      cancellation?: false
    }
  end

  def run(%RunRequest{} = request, opts) do
    send(self(), {:invalid_event_runner_run, request.prompt, opts})
    {:ok, [%{type: :bad, payload: :not_a_map}, %{"type" => 123, "payload" => :not_a_map}]}
  end

  def runtime_contract, do: RuntimeContractStub.build(:invalid_events)
end

defmodule Jido.Harness.Test.RuntimeAdapterStub do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, RunRequest, RuntimeContract}

  def id, do: :runtime_stub

  def capabilities do
    %Capabilities{
      streaming?: true,
      cancellation?: false
    }
  end

  def run(%RunRequest{}, _opts), do: {:ok, []}

  def runtime_contract do
    RuntimeContract.new!(%{
      provider: :runtime_stub,
      host_env_required_any: [],
      host_env_required_all: ["RUNTIME_KEY"],
      sprite_env_forward: [],
      sprite_env_injected: %{},
      runtime_tools_required: ["runtime-tool"],
      compatibility_probes: [
        %{
          "name" => "runtime_probe",
          "command" => "probe-runtime",
          "expect_all" => ["runtime ok"]
        }
      ],
      install_steps: [
        %{
          "tool" => "runtime-tool",
          "when_missing" => true,
          "command" => "install-runtime-tool"
        }
      ],
      auth_bootstrap_steps: ["bootstrap-runtime-auth"],
      triage_command_template: "runtime --triage {{prompt}}",
      coding_command_template: "runtime --coding {{prompt}}",
      success_markers: []
    })
  end
end

defmodule Jido.Harness.Test.OpenCodeRuntimeAdapterStub do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, RunRequest, RuntimeContract}

  def id, do: :opencode

  def capabilities do
    %Capabilities{
      streaming?: false,
      tool_calls?: false,
      tool_results?: false,
      thinking?: false,
      cancellation?: false
    }
  end

  def run(%RunRequest{}, _opts), do: {:ok, []}

  def runtime_contract do
    RuntimeContract.new!(%{
      provider: :opencode,
      host_env_required_any: ["ZAI_API_KEY"],
      host_env_required_all: [],
      sprite_env_forward: ["ZAI_API_KEY", "ZAI_BASE_URL", "OPENCODE_MODEL", "GH_TOKEN", "GITHUB_TOKEN"],
      sprite_env_injected: %{
        "GH_PROMPT_DISABLED" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "ZAI_BASE_URL" => "https://api.z.ai/api/anthropic",
        "OPENCODE_MODEL" => "zai_custom/glm-4.5-air"
      },
      runtime_tools_required: ["opencode"],
      compatibility_probes: [
        %{"name" => "opencode_help_run", "command" => "opencode --help", "expect_all" => ["run"]},
        %{
          "name" => "opencode_run_help_json",
          "command" => "opencode run --help",
          "expect_all" => ["--format", "json"]
        }
      ],
      install_steps: [
        %{
          "tool" => "opencode",
          "when_missing" => true,
          "command" =>
            "if command -v npm >/dev/null 2>&1; then npm install -g opencode-ai; else echo 'npm not available'; exit 1; fi"
        }
      ],
      auth_bootstrap_steps: [
        "cat > opencode.json <<'EOF'\n{\"model\": \"{env:OPENCODE_MODEL}\"}\nEOF",
        "opencode models zai_custom 2>&1 | grep -q 'zai_custom/'"
      ],
      triage_command_template:
        "if command -v timeout >/dev/null 2>&1; then timeout 120 opencode run --model ${OPENCODE_MODEL:-zai_custom/glm-4.5-air} --format json \"$(cat {{prompt_file}})\"; else opencode run --model ${OPENCODE_MODEL:-zai_custom/glm-4.5-air} --format json \"$(cat {{prompt_file}})\"; fi",
      coding_command_template:
        "if command -v timeout >/dev/null 2>&1; then timeout 180 opencode run --model ${OPENCODE_MODEL:-zai_custom/glm-4.5-air} --format json \"$(cat {{prompt_file}})\"; else opencode run --model ${OPENCODE_MODEL:-zai_custom/glm-4.5-air} --format json \"$(cat {{prompt_file}})\"; fi",
      success_markers: [
        %{"type" => "result", "subtype" => "success"},
        %{"status" => "success"}
      ]
    })
  end
end

defmodule Jido.Harness.Test.InvalidEnvRuntimeAdapterStub do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, RunRequest, RuntimeContract}

  def id, do: :runtime_invalid_env

  def capabilities do
    %Capabilities{
      streaming?: true,
      cancellation?: false
    }
  end

  def run(%RunRequest{}, _opts), do: {:ok, []}

  def runtime_contract do
    RuntimeContract.new!(%{
      provider: :runtime_invalid_env,
      host_env_required_any: [],
      host_env_required_all: ["BAD-ENV-NAME"],
      sprite_env_forward: [],
      sprite_env_injected: %{},
      runtime_tools_required: [],
      compatibility_probes: [],
      install_steps: [],
      auth_bootstrap_steps: [],
      triage_command_template: "runtime --triage {{prompt}}",
      coding_command_template: "runtime --coding {{prompt}}",
      success_markers: []
    })
  end
end

defmodule Jido.Harness.Test.NoRuntimeContractAdapterStub do
  @moduledoc false
  alias Jido.Harness.{Capabilities, RunRequest}

  def id, do: :runtime_missing_contract

  def capabilities do
    %Capabilities{
      streaming?: true,
      cancellation?: false
    }
  end

  def run(%RunRequest{}, _opts), do: {:ok, []}
end

defmodule Jido.Harness.Test.MissingTemplatesRuntimeAdapterStub do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, RunRequest, RuntimeContract}

  def id, do: :runtime_missing_templates

  def capabilities do
    %Capabilities{
      streaming?: true,
      cancellation?: false
    }
  end

  def run(%RunRequest{}, _opts), do: {:ok, []}

  def runtime_contract do
    RuntimeContract.new!(%{
      provider: :runtime_missing_templates,
      host_env_required_any: [],
      host_env_required_all: [],
      sprite_env_forward: [],
      sprite_env_injected: %{},
      runtime_tools_required: [],
      compatibility_probes: [],
      install_steps: [],
      auth_bootstrap_steps: [],
      triage_command_template: nil,
      coding_command_template: "runtime --coding {{prompt}}",
      success_markers: []
    })
  end
end

defmodule Jido.Harness.Test.ExecShellState do
  @moduledoc false
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> default_state() end, name: __MODULE__)
  end

  def ensure_started! do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  def reset!(opts \\ %{}) do
    ensure_started!()

    Agent.update(__MODULE__, fn _ ->
      default_state()
      |> Map.merge(Map.take(opts, [:tools, :env]))
    end)
  end

  def runs do
    ensure_started!()
    Agent.get(__MODULE__, &Enum.reverse(&1.runs))
  end

  def set_tool(tool, present?) when is_binary(tool) and is_boolean(present?) do
    ensure_started!()

    Agent.update(__MODULE__, fn state ->
      %{state | tools: Map.put(state.tools, tool, present?)}
    end)
  end

  def set_env(key, value) when is_binary(key) do
    ensure_started!()

    Agent.update(__MODULE__, fn state ->
      %{state | env: Map.put(state.env, key, value)}
    end)
  end

  def run(command) when is_binary(command) do
    ensure_started!()
    Agent.update(__MODULE__, fn state -> %{state | runs: [command | state.runs]} end)

    cond do
      String.contains?(command, "install-runtime-tool") ->
        set_tool("runtime-tool", true)
        {:ok, "installed"}

      String.contains?(command, "bootstrap-runtime-auth") ->
        set_env("RUNTIME_KEY", "set")
        {:ok, "bootstrapped"}

      String.contains?(command, "probe-runtime") ->
        {:ok, "runtime ok"}

      String.contains?(command, "opencode --help") ->
        {:ok, "OpenCode CLI\nrun\n"}

      String.contains?(command, "opencode run --help") ->
        {:ok, "Usage: opencode run --format json"}

      String.contains?(command, "opencode models zai_custom") ->
        {:ok, "zai_custom/glm-4.5-air"}

      String.contains?(command, "gh auth status") ->
        {:ok, "authenticated"}

      String.contains?(command, "gh api user --jq .login") ->
        {:ok, "testuser"}

      String.contains?(command, "${") ->
        env_key = extract_env_key(command)
        env_value = Agent.get(__MODULE__, fn state -> Map.get(state.env, env_key) end)
        {:ok, if(present_env?(env_value), do: "present", else: "missing")}

      String.contains?(command, "command -v ") ->
        tool = extract_tool_name(command)
        present = Agent.get(__MODULE__, fn state -> Map.get(state.tools, tool, false) end)
        {:ok, if(present, do: "present", else: "missing")}

      true ->
        {:ok, "ok"}
    end
  end

  defp extract_env_key(command) do
    case Regex.run(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)[:-]/, command) do
      [_, key] -> key
      _ -> ""
    end
  end

  defp extract_tool_name(command) do
    case Regex.run(~r/command -v '?([A-Za-z0-9._+-]+)'?/, command) do
      [_, tool] -> tool
      _ -> ""
    end
  end

  defp present_env?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_env?(_), do: false

  defp default_state do
    %{
      tools: %{"gh" => true, "git" => true},
      env: %{},
      runs: []
    }
  end
end

defmodule Jido.Harness.Test.ExecShellAgentStub do
  @moduledoc false

  def run(_session_id, command, _opts \\ []) when is_binary(command) do
    Jido.Harness.Test.ExecShellState.run(command)
  end
end
