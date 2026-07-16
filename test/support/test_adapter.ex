defmodule Jido.Harness.TestAdapter do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities, Event, ProviderStatus}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :test,
      name: "Test fixture",
      executable: "fixture",
      capabilities: %Capabilities{streaming?: true, resume?: true},
      normalized_options: [
        :model,
        :session_id,
        :max_turns,
        :system_prompt,
        :allowed_tools,
        :disallowed_tools,
        :add_dirs,
        :mcp_config,
        :approval_mode,
        :sandbox_mode,
        :attachments,
        :reasoning_effort
      ],
      provider_options: [:fixture_mode]
    }
  end

  @impl true
  def status(_config) do
    {:ok,
     %ProviderStatus{
       provider: :test,
       installed: true,
       compatible: true,
       authenticated: true,
       smoke_ready: true,
       capabilities: spec().capabilities,
       executable: "fixture"
     }}
  end

  @impl true
  def run(request, _context) do
    case request.prompt do
      "fail" -> {:error, :fixture_failure}
      "raise" -> raise "fixture raised"
      "wait" -> {:ok, waiting_stream()}
      "slow" -> {:ok, slow_stream(request)}
      _ -> {:ok, successful_stream(request)}
    end
  end

  defp successful_stream(request) do
    [
      event(:turn_started, request, %{"turn" => 1}),
      event(:output_text_delta, request, %{"text" => "fixture-"}),
      event(:output_text_delta, request, %{"text" => "ok"}),
      event(:output_text_final, request, %{"text" => "fixture-ok"}),
      event(:usage, request, %{"input_tokens" => 2, "output_tokens" => 1}),
      event(:turn_completed, request, %{"turn" => 1})
    ]
  end

  defp slow_stream(request) do
    Stream.map(1..3, fn number ->
      Process.sleep(75)
      event(:output_text_delta, request, %{"text" => Integer.to_string(number)})
    end)
  end

  defp waiting_stream do
    Stream.repeatedly(fn ->
      Process.sleep(100)
      Event.new!(provider: :test, type: :thinking_delta, payload: %{"text" => "."})
    end)
  end

  defp event(type, request, payload) do
    Event.new!(provider: :test, type: type, session_id: request.session_id, payload: payload)
  end
end

defmodule Jido.Harness.OwnedCLITestAdapter do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities, Event}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :owned_cli,
      name: "Owned CLI test fixture",
      executable: "/bin/sleep",
      capabilities: %Capabilities{streaming?: true, native_cancel?: true},
      normalized_options: [],
      provider_options: []
    }
  end

  @impl true
  defdelegate status(config), to: Jido.Harness.TestAdapter

  @impl true
  def run(_request, context) do
    spec = %{
      executable: "/bin/sleep",
      argv: ["30"],
      stdin: false,
      metadata: %{run_id: context.run_id, provider: :owned_cli}
    }

    with {:ok, process_id} <- context.process_manager.start_owned_process(spec, context.run_owner),
         {:ok, stream} <- context.process_manager.stream_process(process_id) do
      {:ok,
       Stream.map(stream, fn process_event ->
         Event.new!(
           provider: :owned_cli,
           type: :provider_event,
           payload: %{"process_event" => Atom.to_string(process_event.type)}
         )
       end)}
    end
  end
end

defmodule Jido.Harness.AmpCaptureSDK do
  @moduledoc false

  def execute(prompt, options) do
    send(Process.get(:capture_owner), {:amp_options, prompt, options})
    []
  end
end

defmodule Jido.Harness.ClaudeCaptureSDK do
  @moduledoc false

  def query(prompt, options) do
    send(Process.get(:capture_owner), {:claude_options, :query, prompt, options})
    []
  end

  def resume(session_id, prompt, options) do
    send(Process.get(:capture_owner), {:claude_options, {:resume, session_id}, prompt, options})
    []
  end
end

defmodule Jido.Harness.ZaiCaptureSDK do
  @moduledoc false

  def query(prompt, options) do
    send(Process.get(:capture_owner), {:zai_options, :query, prompt, options})

    [
      %ClaudeAgentSDK.Message{
        type: :system,
        subtype: :init,
        data: %{session_id: "zai-session", cwd: options.cwd, model: options.model, tools: []},
        raw: %{}
      }
    ]
  end

  def resume(session_id, prompt, options) do
    send(Process.get(:capture_owner), {:zai_options, {:resume, session_id}, prompt, options})
    []
  end
end

defmodule Jido.Harness.GeminiCaptureSDK do
  @moduledoc false

  def execute(prompt, options) do
    send(Process.get(:capture_owner), {:gemini_options, prompt, options})
    []
  end
end

defmodule Jido.Harness.CodexCaptureSDK do
  @moduledoc false

  def start_thread(options, thread_options) do
    send(Process.get(:capture_owner), {:codex_options, :start, options, thread_options})
    {:ok, :fake_thread}
  end

  def resume_thread(session_id, options, thread_options) do
    send(Process.get(:capture_owner), {:codex_options, {:resume, session_id}, options, thread_options})
    {:ok, :fake_thread}
  end
end

defmodule Jido.Harness.CodexCaptureThread do
  @moduledoc false

  def run_streamed(:fake_thread, prompt, turn_options) do
    send(Process.get(:capture_owner), {:codex_turn, prompt, turn_options})
    {:ok, :fake_result}
  end
end

defmodule Jido.Harness.CodexCaptureStreaming do
  @moduledoc false
  def events(:fake_result), do: []
end

defmodule Jido.Harness.LimitedTestAdapter do
  @moduledoc false
  @behaviour Jido.Harness.Adapter

  alias Jido.Harness.{AdapterSpec, Capabilities}

  @impl true
  def spec do
    %AdapterSpec{
      provider: :limited,
      name: "Limited test fixture",
      executable: "fixture",
      capabilities: %Capabilities{},
      normalized_options: [],
      provider_options: []
    }
  end

  @impl true
  defdelegate status(config), to: Jido.Harness.TestAdapter

  @impl true
  defdelegate run(request, context), to: Jido.Harness.TestAdapter
end
