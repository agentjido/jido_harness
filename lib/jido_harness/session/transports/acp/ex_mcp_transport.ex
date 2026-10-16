defmodule Jido.Harness.SessionAdapters.ACP.ExMCPTransport do
  @moduledoc false
  @behaviour ExMCP.Transport

  alias Jido.Harness.SessionAdapters.ACP.ExMCPTransport.Bridge

  @type t :: %__MODULE__{bridge: pid()}
  defstruct [:bridge]

  @default_max_frame_bytes 1_048_576

  # One ACP message is one line, and a line carrying an image (a tool result
  # that read one, a prompt with one attached) is larger than the default. The
  # host application raises it with `config :jido_harness, :acp_max_frame_bytes`.
  # The limit stays: it bounds what an agent that never ends its line can make
  # this process hold.
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes do
    case Application.get_env(:jido_harness, :acp_max_frame_bytes, @default_max_frame_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _other -> @default_max_frame_bytes
    end
  end

  @impl true
  def connect(opts) do
    listener = opts |> Keyword.fetch!(:harness_transport) |> Keyword.fetch!(:listener)
    send(listener, {:acp_client_starting, self()})

    with {:ok, bridge} <- opts |> Keyword.fetch!(:harness_transport) |> Bridge.start_link() do
      {:ok, %__MODULE__{bridge: bridge}}
    end
  end

  @impl true
  def send_message(message, %__MODULE__{bridge: bridge} = state) when is_binary(message) do
    case Bridge.send_message(bridge, message) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def receive_message(%__MODULE__{bridge: bridge} = state) do
    case Bridge.receive_message(bridge) do
      {:ok, message} -> {:ok, message, state}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def close(%__MODULE__{bridge: bridge}), do: Bridge.close(bridge)

  @impl true
  def connected?(%__MODULE__{bridge: bridge}), do: Bridge.connected?(bridge)
end

defmodule Jido.Harness.SessionAdapters.ACP.ExMCPTransport.Bridge do
  @moduledoc false
  use GenServer

  alias Jido.Harness.{ProcessEvent, Redaction, TextTail}
  alias Jido.Harness.SessionAdapters.ACP.ExMCPTransport

  @stderr_bytes 4_096
  @lifecycle_limit 8

  # ExMCP's ACP client sends only the requests it knows and keeps only the
  # parts of the initialize response it knows. An extension request (ACP
  # `_session/steering`) goes out here instead, with ids of its own whose
  # responses are taken out of the stream before the client sees them; the
  # initialize response's `_meta`, where an agent advertises its extensions,
  # goes to the listener as `{:acp_agent_meta, bridge, meta}`.
  @extension_id_prefix "jido-harness-ext-"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def send_message(bridge, message), do: GenServer.call(bridge, {:send, message}, :infinity)
  def receive_message(bridge), do: GenServer.call(bridge, :receive, :infinity)

  @doc """
  Sends an ACP extension request and waits at most `timeout` milliseconds
  for its result: `{:ok, result}`, or `{:error, error}` with the agent's
  error, `:timeout`, `:closed` or a request that cannot be encoded. The
  bridge keeps the time, so a request the agent never answers is forgotten.
  """
  @spec extension_request(pid(), String.t(), map(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def extension_request(bridge, method, params, timeout) do
    GenServer.call(bridge, {:extension_request, method, params, timeout}, :infinity)
  catch
    :exit, reason -> {:error, {:transport_exit, reason}}
  end

  def close(bridge) do
    GenServer.call(bridge, :close, 5_000)
  catch
    :exit, _reason -> :ok
  end

  def connected?(bridge) do
    GenServer.call(bridge, :connected?)
  catch
    :exit, _reason -> false
  end

  @impl true
  def init(opts) do
    process_manager = Keyword.fetch!(opts, :process_manager)
    process_owner = Keyword.fetch!(opts, :process_owner)
    process_spec = Keyword.fetch!(opts, :process_spec)
    listener = Keyword.fetch!(opts, :listener)

    with {:ok, process_id} <- process_manager.start_owned_process(process_spec, process_owner),
         {:ok, stream} <- process_manager.stream_process(process_id) do
      {:ok,
       %{
         process_manager: process_manager,
         process_id: process_id,
         listener: listener,
         stream: stream,
         reader: nil,
         buffer: "",
         frames: :queue.new(),
         waiter: nil,
         status: :open,
         stop_notified?: false,
         stderr: TextTail.new(@stderr_bytes),
         lifecycle: [],
         secrets:
           Redaction.secrets_from_env(Map.merge(System.get_env(), if(process_spec, do: process_spec.env, else: %{}))),
         initialized?: false,
         extension_requests: %{},
         next_extension_id: 1
       }, {:continue, :start_reader}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_reader, state) do
    parent = self()

    reader =
      Task.Supervisor.async_nolink(Jido.Harness.SessionTaskSupervisor, fn ->
        Enum.each(state.stream, &send(parent, {:acp_transport_process_event, &1}))
      end)

    {:noreply, %{state | reader: reader}}
  end

  @impl true
  def handle_call({:send, message}, _from, %{status: :open} = state) do
    {:reply, state.process_manager.send_input(state.process_id, message <> "\n"), state}
  end

  def handle_call({:send, _message}, _from, state), do: {:reply, {:error, :closed}, state}

  def handle_call({:extension_request, method, params, timeout}, from, %{status: :open} = state) do
    id = @extension_id_prefix <> Integer.to_string(state.next_extension_id)
    state = %{state | next_extension_id: state.next_extension_id + 1}

    with {:ok, message} <- encode_request(id, method, params),
         :ok <- state.process_manager.send_input(state.process_id, message <> "\n") do
      timer = Process.send_after(self(), {:extension_timeout, id}, timeout)
      {:noreply, %{state | extension_requests: Map.put(state.extension_requests, id, {from, timer})}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:extension_request, _method, _params, _timeout}, _from, state),
    do: {:reply, {:error, :closed}, state}

  def handle_call(:receive, from, state) do
    case :queue.out(state.frames) do
      {{:value, frame}, rest} ->
        {:reply, {:ok, frame}, %{state | frames: rest}}

      {:empty, _frames} ->
        wait_for_frame(from, state)
    end
  end

  def handle_call(:connected?, _from, state), do: {:reply, state.status == :open, state}

  def handle_call(:close, _from, state) do
    _ = state.process_manager.cancel_process(state.process_id)

    if function_exported?(state.process_manager, :await_process, 2) do
      _ = state.process_manager.await_process(state.process_id, 2_000)
    end

    state = close_state(state, :closed, true)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:acp_transport_process_event, %ProcessEvent{type: :stdout, data: data}}, state) do
    case split_frames(state.buffer, data) do
      {:ok, frames, buffer} ->
        {frames, state} = Enum.flat_map_reduce(frames, %{state | buffer: buffer}, &inspect_frame/2)
        {:noreply, enqueue_frames(state, frames)}

      {:error, reason} ->
        {:noreply, stop_for_process_event(state, :failed, reason)}
    end
  end

  def handle_info({:acp_transport_process_event, %ProcessEvent{type: :stderr, data: data}}, state) do
    send(state.listener, {:acp_process_stderr, data})
    {:noreply, %{state | stderr: TextTail.append(state.stderr, data)}}
  end

  def handle_info({:acp_transport_process_event, %ProcessEvent{type: :started} = event}, state) do
    {:noreply, record_lifecycle(state, event)}
  end

  def handle_info({:acp_transport_process_event, %ProcessEvent{type: type, data: data} = event}, state)
      when type in [:failed, :timed_out, :exited, :cancelled] do
    state = record_lifecycle(state, event)
    details = diagnostics(state, type, data)
    {:noreply, stop_for_process_event(state, type, details)}
  end

  def handle_info({ref, _result}, %{reader: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      if state.status == :open,
        do: stop_for_process_event(state, :stream_ended, nil),
        else: state

    {:noreply, %{state | reader: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reader: %{ref: ref}} = state) do
    state =
      if state.status == :open,
        do: stop_for_process_event(state, :reader_exit, reason),
        else: state

    {:noreply, %{state | reader: nil}}
  end

  def handle_info({:extension_timeout, id}, state) do
    case Map.pop(state.extension_requests, id) do
      {{from, _timer}, requests} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | extension_requests: requests}}

      {nil, _requests} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.reader, do: Task.shutdown(state.reader, 1_000)
    _ = state.process_manager.cancel_process(state.process_id)
    :ok
  rescue
    _exception -> :ok
  end

  defp wait_for_frame(from, %{status: :open, waiter: nil} = state),
    do: {:noreply, %{state | waiter: from}}

  defp wait_for_frame(_from, %{status: :open} = state),
    do: {:reply, {:error, :receiver_busy}, state}

  defp wait_for_frame(_from, %{status: {:process_stopped, type, data}} = state) do
    state = notify_process_stopped(state, type, data)
    {:reply, {:error, {:process_stopped, type, data}}, state}
  end

  defp wait_for_frame(_from, state), do: {:reply, {:error, :closed}, state}

  defp split_frames(buffer, data) when is_binary(data) do
    parts = :binary.split(buffer <> data, "\n", [:global])
    {lines, [rest]} = Enum.split(parts, -1)
    frames = lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    limit = ExMCPTransport.max_frame_bytes()

    cond do
      Enum.any?(frames, &(byte_size(&1) > limit)) -> {:error, :frame_too_large}
      byte_size(rest) > limit -> {:error, :frame_too_large}
      true -> {:ok, frames, rest}
    end
  end

  # Only a frame that can be one of ours is decoded: frames carry whole files
  # and images, and the client decodes them again anyway.
  defp inspect_frame(frame, state) do
    cond do
      :binary.match(frame, @extension_id_prefix) != :nomatch -> take_extension_response(frame, state)
      not state.initialized? and :binary.match(frame, "protocolVersion") != :nomatch -> note_initialize(frame, state)
      true -> {[frame], state}
    end
  end

  defp take_extension_response(frame, state) do
    with {:ok, %{"id" => id} = message} when not is_map_key(message, "method") <- Jason.decode(frame),
         {{from, timer}, requests} <- Map.pop(state.extension_requests, id) do
      Process.cancel_timer(timer, async: true, info: false)
      GenServer.reply(from, extension_result(message))
      {[], %{state | extension_requests: requests}}
    else
      _other -> {[frame], state}
    end
  end

  # Input that is not valid UTF-8 cannot be sent; it is refused, and the
  # session goes on.
  defp encode_request(id, method, params) do
    limit = ExMCPTransport.max_frame_bytes()

    case Jason.encode(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) do
      {:ok, message} when byte_size(message) > limit -> {:error, :frame_too_large}
      {:ok, message} -> {:ok, message}
      {:error, error} -> {:error, {:invalid_request, Exception.message(error)}}
    end
  end

  defp extension_result(%{"error" => error}), do: {:error, error}
  defp extension_result(message), do: {:ok, Map.get(message, "result")}

  defp note_initialize(frame, state) do
    case Jason.decode(frame) do
      {:ok, %{"result" => %{"protocolVersion" => _version} = result}} ->
        meta = if is_map(result["_meta"]), do: result["_meta"], else: %{}
        send(state.listener, {:acp_agent_meta, self(), meta})
        {[frame], %{state | initialized?: true}}

      _other ->
        {[frame], state}
    end
  end

  defp enqueue_frames(state, []), do: state

  defp enqueue_frames(%{waiter: waiter} = state, [frame | frames]) when not is_nil(waiter) do
    GenServer.reply(waiter, {:ok, frame})
    enqueue_frames(%{state | waiter: nil}, frames)
  end

  defp enqueue_frames(state, frames) do
    queue = Enum.reduce(frames, state.frames, &:queue.in(&1, &2))
    %{state | frames: queue}
  end

  defp record_lifecycle(state, event) do
    entry = %{"type" => Atom.to_string(event.type), "sequence" => event.sequence, "data" => event.data}
    %{state | lifecycle: Enum.take(state.lifecycle ++ [entry], -@lifecycle_limit)}
  end

  defp diagnostics(state, type, data) do
    stderr = state.stderr.data
    stderr = if state.stderr.truncated?, do: redact_clipped_secrets(stderr, state.secrets), else: stderr
    stderr = TextTail.new(@stderr_bytes) |> TextTail.append(Redaction.redact(stderr, state.secrets))

    %{
      "process_id" => state.process_id,
      "state" => Atom.to_string(type),
      "details" => data,
      "stderr" => stderr.data,
      "stderr_truncated" => state.stderr.truncated? or stderr.truncated?,
      "lifecycle" => state.lifecycle
    }
    |> Redaction.redact(state.secrets)
  end

  defp redact_clipped_secrets(value, secrets) do
    Enum.reduce(secrets, value, fn secret, value ->
      maximum = min(byte_size(secret) - 1, byte_size(value))

      overlap =
        Enum.find(maximum..1//-1, fn size ->
          String.starts_with?(value, binary_part(secret, byte_size(secret) - size, size))
        end)

      if overlap, do: "[REDACTED]" <> binary_part(value, overlap, byte_size(value) - overlap), else: value
    end)
  end

  defp stop_for_process_event(%{status: :open} = state, type, data) do
    waiting? = not is_nil(state.waiter)
    state = close_state(state, {:process_stopped, type, data}, false)
    if waiting?, do: notify_process_stopped(state, type, data), else: state
  end

  defp stop_for_process_event(state, _type, _data), do: state

  defp close_state(state, reason, clear_frames?) do
    if state.waiter, do: GenServer.reply(state.waiter, {:error, receive_error(reason)})

    Enum.each(state.extension_requests, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer, async: true, info: false)
      GenServer.reply(from, {:error, :closed})
    end)

    %{
      state
      | status: reason,
        waiter: nil,
        extension_requests: %{},
        frames: if(clear_frames?, do: :queue.new(), else: state.frames),
        buffer: ""
    }
  end

  defp receive_error({:process_stopped, type, data}), do: {:process_stopped, type, data}
  defp receive_error(reason), do: reason

  defp notify_process_stopped(%{stop_notified?: true} = state, _type, _data), do: state

  defp notify_process_stopped(state, type, data) do
    send(state.listener, {:acp_process_stopped, type, data})
    %{state | stop_notified?: true}
  end
end
