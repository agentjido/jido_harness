defmodule Jido.Harness.Test.AdapterStub do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{Capabilities, Event, RunRequest}

  def id, do: :adapter_stub

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

  def run(prompt, opts) when is_binary(prompt) and is_list(opts), do: {:ok, "done"}
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

  def run(prompt, opts) when is_binary(prompt) and is_list(opts), do: {:error, :boom}
end

defmodule Jido.Harness.Test.InvalidEventRunnerStub do
  @moduledoc false

  def run(prompt, opts) when is_binary(prompt) and is_list(opts) do
    send(self(), {:invalid_event_runner_run, prompt, opts})
    {:ok, [%{type: :bad, payload: :not_a_map}, %{"type" => 123, "payload" => :not_a_map}]}
  end
end
