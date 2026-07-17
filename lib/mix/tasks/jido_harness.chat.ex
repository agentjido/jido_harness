defmodule Mix.Tasks.JidoHarness.Chat do
  @moduledoc """
  Opens an interactive Jido.Harness session without driving a provider TUI.

      mix jido_harness.chat codex
      mix jido_harness.chat codex --transport app_server --format jsonl

  Enter text directly or use `/send`. Available commands are `/follow-up`,
  `/steer`, `/interrupt`, `/approve`, `/deny`, `/status`, and `/close`.
  Provider requests may consume paid API or subscription usage.
  """
  use Mix.Task

  alias Jido.Harness.{Event, SessionInfo}

  @shortdoc "Open an interactive harness session"

  @impl true
  def run(args) do
    {options, provider} = parse_args(args)
    Mix.Task.run("app.start")

    provider = provider_atom!(provider)
    request = session_request(options)

    case Jido.Harness.open_session(provider, request) do
      {:ok, session_id} ->
        Mix.shell().info("[#{provider}] session_id=#{session_id} transport=#{options[:transport] || "default"}")
        Mix.shell().info("Type a message, /status, or /close. Use /help for all commands.")
        printer = start_printer(session_id, options[:format])

        try do
          command_loop(session_id)
        after
          close_if_open(session_id)
          await_printer(printer)
        end

      {:error, error} ->
        Mix.raise("could not open #{provider} session: #{format_error(error)}")
    end
  end

  @doc false
  def parse_args(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          model: :string,
          provider_session_id: :string,
          transport: :string,
          format: :string,
          approval: :string,
          sandbox: :string,
          env_file: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid chat options: #{inspect(invalid)}")

    provider =
      case positional do
        [provider] -> provider
        _ -> Mix.raise("usage: mix jido_harness.chat PROVIDER [--transport NAME] [--format pretty|jsonl]")
      end

    format = Keyword.get(options, :format, "pretty")
    unless format in ["pretty", "jsonl"], do: Mix.raise("--format must be pretty or jsonl")

    if path = options[:env_file], do: Mix.Tasks.JidoHarness.Integration.load_env_file(path)

    options =
      options
      |> Keyword.put(:format, format)
      |> parse_enum(:approval, [:default, :prompt, :auto_edit, :auto_approve])
      |> parse_enum(:sandbox, [:default, :read_only, :workspace_write, :unrestricted])
      |> parse_transport()

    {options, provider}
  end

  defp command_loop(session_id) do
    case IO.gets("harness> ") do
      :eof ->
        :ok

      {:error, reason} ->
        Mix.shell().error("input failed: #{inspect(reason)}")

      input ->
        input = String.trim(input)

        case dispatch(session_id, input) do
          :close -> :ok
          _ -> command_loop(session_id)
        end
    end
  end

  @doc false
  def dispatch(_session_id, ""), do: :ok

  def dispatch(_session_id, "/help") do
    Mix.shell().info("""
    /send TEXT                 send now (session must be idle)
    /follow-up TEXT            queue after the active turn
    /steer TEXT                steer the active turn when supported
    /interrupt                 interrupt the active turn
    /approve REQUEST [session] approve once or for this session
    /deny REQUEST              deny an approval request
    /status                    show session state and capabilities
    /close                     gracefully close the session
    """)

    :ok
  end

  def dispatch(session_id, "/status") do
    with {:ok, %SessionInfo{} = info} <- Jido.Harness.info_session(session_id) do
      Mix.shell().info(
        "state=#{info.state} transport=#{info.transport} active_turn=#{info.active_turn_id || "none"} " <>
          "queued=#{info.queued_turns} approvals=#{info.pending_approvals} provider_session_id=#{info.provider_session_id || "none"}"
      )
    else
      error -> print_error(error)
    end

    :ok
  end

  def dispatch(session_id, "/interrupt") do
    print_reply(Jido.Harness.interrupt_turn(session_id))
    :ok
  end

  def dispatch(session_id, "/close") do
    print_reply(Jido.Harness.close_session(session_id))
    :close
  end

  def dispatch(session_id, "/approve " <> arguments) do
    case String.split(arguments, ~r/\s+/, trim: true) do
      [request_id] ->
        print_reply(Jido.Harness.respond_approval(session_id, request_id, :approve))

      [request_id, "session"] ->
        print_reply(Jido.Harness.respond_approval(session_id, request_id, %{decision: :approve, scope: :session}))

      _ ->
        Mix.shell().error("usage: /approve REQUEST_ID [session]")
    end

    :ok
  end

  def dispatch(session_id, "/deny " <> request_id) do
    request_id = String.trim(request_id)

    if request_id == "",
      do: Mix.shell().error("usage: /deny REQUEST_ID"),
      else: print_reply(Jido.Harness.respond_approval(session_id, request_id, :deny))

    :ok
  end

  def dispatch(session_id, "/send " <> text), do: send_input(session_id, :send, text)
  def dispatch(session_id, "/follow-up " <> text), do: send_input(session_id, :follow_up, text)
  def dispatch(session_id, "/steer " <> text), do: send_input(session_id, :steer, text)

  def dispatch(_session_id, "/" <> command) do
    Mix.shell().error("unknown or incomplete command: /#{command}")
    :ok
  end

  def dispatch(session_id, text), do: send_input(session_id, :send, text)

  defp send_input(session_id, operation, text) do
    text = String.trim(text)

    result =
      case operation do
        :send -> Jido.Harness.send_message(session_id, text)
        :follow_up -> Jido.Harness.follow_up(session_id, text)
        :steer -> Jido.Harness.steer(session_id, text)
      end

    case result do
      {:ok, id} -> Mix.shell().info("#{operation}=#{id}")
      other -> print_reply(other)
    end

    :ok
  end

  defp start_printer(session_id, format) do
    Task.async(fn ->
      case Jido.Harness.stream_session(session_id, poll_interval_ms: 25) do
        {:ok, stream} -> Enum.each(stream, &print_event(&1, format))
        {:error, reason} -> Mix.shell().error("session stream failed: #{format_error(reason)}")
      end
    end)
  end

  defp print_event(%Event{} = event, "jsonl") do
    event = event |> Map.from_struct() |> Map.put(:raw, nil)
    Mix.shell().info(Jason.encode!(event))
  end

  defp print_event(%Event{type: :output_text_delta, payload: %{"text" => text}}, "pretty"), do: IO.write(text)

  defp print_event(%Event{type: :thinking_delta, payload: %{"text" => text}}, "pretty"),
    do: IO.write("[thinking] #{text}")

  defp print_event(%Event{type: type} = event, "pretty")
       when type in [
              :turn_started,
              :turn_completed,
              :turn_failed,
              :turn_interrupted,
              :approval_requested,
              :session_failed
            ] do
    suffix =
      [event.turn_id, event.request_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    details = if map_size(event.payload) == 0, do: "", else: " #{inspect(event.payload, limit: 20)}"
    Mix.shell().info("\n[#{type}] #{suffix}#{details}" |> String.trim_trailing())
  end

  defp print_event(_event, "pretty"), do: :ok

  defp await_printer(task) do
    Task.await(task, 5_000)
  catch
    :exit, _reason -> Task.shutdown(task, :brutal_kill)
  end

  defp close_if_open(session_id) do
    case Jido.Harness.info_session(session_id) do
      {:ok, %SessionInfo{} = info} ->
        if SessionInfo.terminal?(info), do: :ok, else: Jido.Harness.close_session(session_id)

      _ ->
        :ok
    end
  end

  defp session_request(options) do
    %{
      cwd: Path.expand(Keyword.get(options, :cwd, File.cwd!())),
      metadata: %{"source" => "mix jido_harness.chat"}
    }
    |> put_optional(:model, options[:model])
    |> put_optional(:provider_session_id, options[:provider_session_id])
    |> put_optional(:transport, options[:transport])
    |> put_optional(:approval_mode, options[:approval])
    |> put_optional(:sandbox_mode, options[:sandbox])
  end

  defp provider_atom!(name) do
    case Enum.find(Jido.Harness.providers(), &(Atom.to_string(&1.provider) == name)) do
      nil ->
        Mix.raise("unknown provider #{name}; available: #{Enum.map_join(Jido.Harness.providers(), ",", & &1.provider)}")

      spec ->
        spec.provider
    end
  end

  defp parse_transport(options) do
    case options[:transport] do
      nil ->
        options

      value ->
        try do
          Keyword.put(options, :transport, String.to_existing_atom(value))
        rescue
          ArgumentError -> Mix.raise("unknown session transport: #{value}")
        end
    end
  end

  defp parse_enum(options, key, allowed) do
    case options[key] do
      nil ->
        options

      value ->
        atom = Enum.find(allowed, &(Atom.to_string(&1) == value))

        if atom,
          do: Keyword.put(options, key, atom),
          else: Mix.raise("--#{key} must be one of #{Enum.join(allowed, ", ")}")
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp print_reply(:ok), do: :ok
  defp print_reply({:ok, value}), do: Mix.shell().info(inspect(value))
  defp print_reply({:error, reason}), do: print_error(reason)
  defp print_reply(other), do: Mix.shell().info(inspect(other))
  defp print_error({:error, reason}), do: print_error(reason)
  defp print_error(reason), do: Mix.shell().error(format_error(reason))
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason, limit: 30, printable_limit: 2_000)
end
