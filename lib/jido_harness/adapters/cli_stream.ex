defmodule Jido.Harness.Adapters.CLIStream do
  @moduledoc false

  alias Jido.Harness.{Adapters.Helpers, Error, ProcessEvent, ProcessManager, RunRequest}

  def run(provider, %RunRequest{} = request, context, executable, argv, mapper) do
    spec = %{
      executable: executable,
      argv: argv,
      cwd: request.cwd,
      env: request.env,
      runtime_timeout_ms: request.runtime_timeout_ms,
      idle_timeout_ms: request.idle_timeout_ms,
      stdin: false,
      pty: false,
      metadata: %{run_id: context.run_id, provider: provider}
    }

    with {:ok, process_id} <- ProcessManager.start_owned_process(spec, context.run_owner),
         {:ok, process_stream} <- ProcessManager.stream_process(process_id) do
      {:ok, decode(process_stream, provider, mapper)}
    end
  end

  defp decode(stream, provider, mapper) do
    Stream.transform(
      stream,
      fn -> "" end,
      fn
        %ProcessEvent{type: :stdout, data: data}, buffer ->
          {lines, rest} = split_lines(buffer <> data)
          {Enum.flat_map(lines, &map_line(&1, provider, mapper)), rest}

        %ProcessEvent{type: :stderr, data: data}, buffer ->
          {[Helpers.event(provider, :provider_event, nil, %{"stream" => "stderr", "data" => data})], buffer}

        %ProcessEvent{type: :failed, data: data}, buffer ->
          {flush(buffer, provider, mapper) ++
             [Helpers.event(provider, :session_failed, nil, %{"error" => inspect(data)})], ""}

        %ProcessEvent{type: :timed_out}, buffer ->
          {flush(buffer, provider, mapper) ++
             [Helpers.event(provider, :session_failed, nil, %{"error" => "process timed out"})], ""}

        %ProcessEvent{type: :cancelled}, buffer ->
          {flush(buffer, provider, mapper) ++
             [Helpers.event(provider, :session_cancelled, nil, %{"reason" => "cancelled"})], ""}

        %ProcessEvent{type: :exited}, buffer ->
          {flush(buffer, provider, mapper), ""}

        _event, buffer ->
          {[], buffer}
      end,
      fn buffer -> flush(buffer, provider, mapper) end
    )
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp flush("", _provider, _mapper), do: []
  defp flush(buffer, provider, mapper), do: map_line(buffer, provider, mapper)

  defp map_line(line, provider, mapper) do
    line = String.trim(line)

    if line == "" do
      []
    else
      case Jason.decode(line) do
        {:ok, value} ->
          List.wrap(mapper.(value))

        {:error, reason} ->
          [
            Helpers.event(
              provider,
              :provider_event,
              nil,
              %{"mapped" => false, "decode_error" => Exception.message(reason)},
              line
            )
          ]
      end
    end
  rescue
    exception ->
      [
        Helpers.event(
          provider,
          :session_failed,
          nil,
          %{"error" => Exception.message(exception)},
          Error.execution("CLI event mapping failed", provider: provider, cause: exception)
        )
      ]
  end
end
