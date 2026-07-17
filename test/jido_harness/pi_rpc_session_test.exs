defmodule Jido.Harness.PiRPCSessionTest do
  use ExUnit.Case, async: false

  setup do
    providers = Application.get_env(:jido_harness, :providers)
    config = Application.get_env(:jido_harness, :provider_config)
    fixture = Jido.Harness.TestHelpers.fixture_path("fake_pi_rpc.py")
    journal_dir = Path.join(System.tmp_dir!(), "jido-harness-pi-#{System.unique_integer([:positive])}")

    Application.put_env(:jido_harness, :providers, %{pi: Jido.Harness.Adapters.Pi})

    Application.put_env(:jido_harness, :provider_config, %{
      pi: %{cli_path: fixture, retention: %{journal_dir: journal_dir}}
    })

    on_exit(fn ->
      Jido.Harness.TestHelpers.cleanup_sessions()
      Jido.Harness.TestHelpers.cleanup_processes()
      restore(:providers, providers)
      restore(:provider_config, config)
      File.rm_rf!(journal_dir)
    end)

    :ok
  end

  test "Pi RPC preserves context and supports native steering and configuration" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:pi)
    assert {:ok, %{provider_session_id: "pi-fixture-session", transport: :rpc}} = await_ready(session_id)

    assert :ok = Jido.Harness.Session.configure(session_id, %{reasoning_effort: :high})

    assert {:error, %Jido.Harness.Error{details: %{field: :approval_mode}}} =
             Jido.Harness.Session.configure(session_id, %{approval_mode: :auto_approve})

    assert {:ok, first_id} = Jido.Harness.Session.send_message(session_id, %{prompt: "first", reasoning_effort: :low})
    assert {:ok, %{status: :completed, text: "fixture-1"}} = Jido.Harness.Session.await(session_id, first_id, 2_000)

    assert {:ok, held_id} = Jido.Harness.Session.send_message(session_id, "hold")

    assert {:error, %Jido.Harness.Error{details: %{field: :reasoning_effort}}} =
             Jido.Harness.Session.steer(session_id, %{prompt: "ignored", reasoning_effort: :high})

    assert {:ok, _request_id} = Jido.Harness.Session.steer(session_id, "finish")
    assert {:ok, %{status: :completed, text: "steered"}} = Jido.Harness.Session.await(session_id, held_id, 2_000)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    assert Enum.any?(events, &(&1.type == :input_accepted and &1.payload["kind"] == "steer"))
    assert Enum.any?(events, &(&1.type == :provider_event and &1.payload["kind"] == "rpc_response"))
  end

  test "Pi interruption leaves the session usable for another turn" do
    assert {:ok, session_id} = Jido.Harness.Session.start(:pi)
    assert {:ok, _info} = await_ready(session_id)
    assert {:ok, held_id} = Jido.Harness.Session.send_message(session_id, "hold")
    assert :ok = Jido.Harness.Session.interrupt(session_id, held_id)
    assert {:ok, %{status: :interrupted}} = Jido.Harness.Session.await(session_id, held_id, 2_000)

    assert {:ok, next_id} = eventually_send(session_id, "next")
    assert {:ok, %{status: :completed, text: "fixture-1"}} = Jido.Harness.Session.await(session_id, next_id, 2_000)

    assert {:ok, events} = Jido.Harness.Session.replay(session_id, limit: 1_000)
    assert Enum.count(events, &(&1.turn_id == held_id and Jido.Harness.Event.turn_terminal?(&1))) == 1
  end

  defp await_ready(session_id, attempts \\ 100)
  defp await_ready(_session_id, 0), do: {:error, :timeout}

  defp await_ready(session_id, attempts) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{state: :idle, provider_session_id: id}} = result when is_binary(id) ->
        result

      _ ->
        Process.sleep(10)
        await_ready(session_id, attempts - 1)
    end
  end

  defp eventually_send(session_id, input, attempts \\ 100)
  defp eventually_send(_session_id, _input, 0), do: {:error, :timeout}

  defp eventually_send(session_id, input, attempts) do
    case Jido.Harness.Session.send_message(session_id, input) do
      {:error, :busy} ->
        Process.sleep(10)
        eventually_send(session_id, input, attempts - 1)

      result ->
        result
    end
  end

  defp restore(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore(key, value), do: Application.put_env(:jido_harness, key, value)
end
