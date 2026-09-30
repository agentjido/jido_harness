alias Jido.Harness.Process, as: NativeProcess

Enum.each(1..100, fn batch ->
  {:ok, timed_out} =
    NativeProcess.start(%{
      executable: "/bin/sleep",
      argv: ["20"],
      stdin: false,
      runtime_timeout_ms: 100
    })

  ids =
    Enum.map(1..8, fn number ->
      {:ok, id} = NativeProcess.start(%{executable: "/bin/echo", argv: [Integer.to_string(number)], stdin: false})
      id
    end)

  Enum.each([{timed_out, :timed_out} | Enum.map(ids, &{&1, :exited})], fn {id, expected} ->
    {:ok, info} = NativeProcess.await(id, 5_000)
    {:ok, events} = NativeProcess.replay(id, limit: 20)

    if info.state != expected do
      IO.inspect(%{batch: batch, expected: expected, info: info, events: events},
        label: "native failure",
        limit: :infinity
      )

      System.halt(1)
    end

    :ok = NativeProcess.prune(id)
  end)
end)

IO.puts("100 timeouts and 800 native echo processes passed without retries.")
