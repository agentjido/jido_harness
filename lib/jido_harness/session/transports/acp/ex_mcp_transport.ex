defmodule Jido.Harness.SessionAdapters.ACP.ExMCPTransport do
  @moduledoc false
  @behaviour ExMCP.Transport

  alias Jido.Harness.SessionAdapters.ACP.ExMCPTransport.Bridge

  @type t :: %__MODULE__{bridge: pid()}
  defstruct [:bridge]

  @impl true
  def connect(opts) do
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

  alias Jido.Harness.ProcessEvent

  @max_frame_bytes 1_048_576

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def send_message(bridge, message), do: GenServer.call(bridge, {:send, message}, :infinity)
  def receive_message(bridge), do: GenServer.call(bridge, :receive, :infinity)

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
         stop_notified?: false
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
    state = close_state(state, :closed, true)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:acp_transport_process_event, %ProcessEvent{type: :stdout, data: data}}, state) do
    case split_frames(state.buffer, data) do
      {:ok, frames, buffer} -> {:noreply, enqueue_frames(%{state | buffer: buffer}, frames)}
      {:error, reason} -> {:noreply, stop_for_process_event(state, :failed, reason)}
    end
  end

  def handle_info({:acp_transport_process_event, %ProcessEvent{type: :stderr, data: data}}, state) do
    send(state.listener, {:acp_process_stderr, data})
    {:noreply, state}
  end

  def handle_info({:acp_transport_process_event, %ProcessEvent{type: type, data: data}}, state)
      when type in [:failed, :timed_out, :exited, :cancelled] do
    {:noreply, stop_for_process_event(state, type, data)}
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
    {:reply, {:error, {:process_stopped, type}}, state}
  end

  defp wait_for_frame(_from, state), do: {:reply, {:error, :closed}, state}

  defp split_frames(buffer, data) when is_binary(data) do
    parts = :binary.split(buffer <> data, "\n", [:global])
    {lines, [rest]} = Enum.split(parts, -1)
    frames = lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      Enum.any?(frames, &(byte_size(&1) > @max_frame_bytes)) -> {:error, :frame_too_large}
      byte_size(rest) > @max_frame_bytes -> {:error, :frame_too_large}
      true -> {:ok, frames, rest}
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

  defp stop_for_process_event(%{status: :open} = state, type, data) do
    waiting? = not is_nil(state.waiter)
    state = close_state(state, {:process_stopped, type}, false)
    if waiting?, do: notify_process_stopped(state, type, data), else: state
  end

  defp stop_for_process_event(state, _type, _data), do: state

  defp close_state(state, reason, clear_frames?) do
    if state.waiter, do: GenServer.reply(state.waiter, {:error, reason})

    %{
      state
      | status: reason,
        waiter: nil,
        frames: if(clear_frames?, do: :queue.new(), else: state.frames),
        buffer: ""
    }
  end

  defp notify_process_stopped(%{stop_notified?: true} = state, _type, _data), do: state

  defp notify_process_stopped(state, type, data) do
    send(state.listener, {:acp_process_stopped, type, data})
    %{state | stop_notified?: true}
  end
end
