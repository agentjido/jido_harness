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
        :provider_session_id,
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
      "fail" ->
        {:error, :fixture_failure}

      "terminal-fail" ->
        {:ok, [Event.new!(provider: :test, type: :run_failed, payload: %{"error" => "fixture terminal failure"})]}

      "raise" ->
        raise "fixture raised"

      "wait" ->
        {:ok, waiting_stream()}

      "slow" ->
        {:ok, slow_stream(request)}

      "large" ->
        {:ok, large_stream(request)}

      _ ->
        {:ok, successful_stream(request)}
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

  defp large_stream(request) do
    text = String.duplicate("0123456789", 1_000)

    [
      event(:output_text_final, request, %{"text" => text}),
      event(:turn_completed, request, %{})
    ]
  end

  defp event(type, request, payload) do
    Event.new!(
      provider: :test,
      type: type,
      provider_session_id: request.provider_session_id || "fixture-session",
      payload: payload
    )
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
