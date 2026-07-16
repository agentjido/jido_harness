duration = System.argv() |> List.first() |> case do nil -> 3_900_000; value -> String.to_integer(value) end
interval = System.argv() |> Enum.at(1, "1000") |> String.to_integer()
started = System.monotonic_time(:millisecond)

Stream.iterate(0, &(&1 + 1))
|> Enum.reduce_while(:ok, fn sequence, _acc ->
  elapsed = System.monotonic_time(:millisecond) - started
  IO.puts(~s({"type":"tick","sequence":#{sequence},"elapsed_ms":#{elapsed}}))

  if elapsed >= duration do
    {:halt, :ok}
  else
    Process.sleep(interval)
    {:cont, :ok}
  end
end)
