defmodule Jido.Harness.WaitersTest do
  use ExUnit.Case, async: true
  alias Jido.Harness.Waiters

  test "reply and cancellation remove all indexes and monitors" do
    first = make_ref()
    second = make_ref()
    waiters = %{} |> Waiters.add(first, {self(), first}, :a) |> Waiters.add(second, {self(), second}, :b)
    monitor = waiters[first].monitor
    waiters = Waiters.reply(waiters, :a, :done)
    assert_receive {^first, :done}
    refute Map.has_key?(waiters, {:monitor, monitor})
    assert Map.has_key?(waiters, second)
    assert %{} == Waiters.drop_monitor(waiters, waiters[second].monitor)
    refute {:process, self()} in elem(Process.info(self(), :monitors), 1)
  end

  test "duplicate requests replace their monitor and unknown DOWN is harmless" do
    ref = make_ref()
    waiters = Waiters.add(%{}, ref, {self(), ref})
    old = waiters[ref].monitor
    waiters = Waiters.add(waiters, ref, {self(), ref})
    refute Map.has_key?(waiters, {:monitor, old})
    assert Waiters.drop_monitor(waiters, make_ref()) == waiters
    assert Waiters.reply_all(waiters, :done) == %{}
    assert_receive {^ref, :done}
  end
end
