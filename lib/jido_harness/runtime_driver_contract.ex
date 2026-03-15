defmodule Jido.Harness.RuntimeDriverContract do
  @moduledoc """
  Shared conformance tests for Session Control runtime drivers.

  ## Usage

      defmodule MyRuntimeDriverTest do
        use ExUnit.Case, async: false
        use Jido.Harness.RuntimeDriverContract,
          driver: My.RuntimeDriver,
          start_session_opts: [provider: :claude],
          check_stream_run: true,
          check_run: true,
          run_request: %{prompt: "hello", metadata: %{}}
      end
  """

  defmacro __using__(opts) do
    quote do
      import Jido.Harness.RuntimeDriverContract
      runtime_driver_contract(unquote(opts))
    end
  end

  defmacro runtime_driver_contract(opts) do
    driver = opts |> Keyword.fetch!(:driver) |> Macro.expand(__CALLER__)
    start_session_opts = Keyword.get(opts, :start_session_opts, [])
    descriptor_opts = Keyword.get(opts, :descriptor_opts, start_session_opts)
    check_stream_run = Keyword.get(opts, :check_stream_run, false)
    check_run = Keyword.get(opts, :check_run, false)
    run_request = Keyword.get(opts, :run_request, %{prompt: "contract smoke", metadata: %{}})
    run_opts = Keyword.get(opts, :run_opts, [])

    quote bind_quoted: [
            driver: driver,
            start_session_opts: start_session_opts,
            descriptor_opts: descriptor_opts,
            check_stream_run: check_stream_run,
            check_run: check_run,
            run_request: run_request,
            run_opts: run_opts
          ] do
      alias Jido.Harness.{
        ExecutionEvent,
        ExecutionResult,
        ExecutionStatus,
        RunHandle,
        RunRequest,
        RuntimeDescriptor,
        SessionHandle
      }

      @runtime_driver_contract_driver driver
      @runtime_driver_contract_start_session_opts start_session_opts
      @runtime_driver_contract_descriptor_opts descriptor_opts
      @runtime_driver_contract_run_request run_request
      @runtime_driver_contract_run_opts run_opts

      defp __runtime_driver_contract_resolve_module__(value) when is_atom(value), do: value

      test "runtime driver contract: required callbacks are exported" do
        driver = __runtime_driver_contract_resolve_module__(@runtime_driver_contract_driver)
        assert Code.ensure_loaded?(driver), "runtime driver module could not be loaded: #{inspect(driver)}"
        assert function_exported?(driver, :runtime_id, 0)
        assert function_exported?(driver, :runtime_descriptor, 1)
        assert function_exported?(driver, :start_session, 1)
        assert function_exported?(driver, :stop_session, 1)
        assert function_exported?(driver, :stream_run, 3)
        assert function_exported?(driver, :cancel_run, 2)
        assert function_exported?(driver, :session_status, 1)
      end

      test "runtime driver contract: runtime_descriptor/1 returns descriptor struct" do
        driver = __runtime_driver_contract_resolve_module__(@runtime_driver_contract_driver)
        descriptor = driver.runtime_descriptor(@runtime_driver_contract_descriptor_opts)

        assert %RuntimeDescriptor{} = descriptor
        assert is_atom(descriptor.runtime_id)
        assert is_binary(descriptor.label)
        assert is_atom(descriptor.session_mode)

        for key <- [:streaming?, :cancellation?, :approvals?, :cost?, :subscribe?, :resume?] do
          assert is_boolean(Map.get(descriptor, key))
        end
      end

      test "runtime driver contract: start_session/1 and session_status/1 return session control structs" do
        driver = __runtime_driver_contract_resolve_module__(@runtime_driver_contract_driver)
        assert {:ok, session} = driver.start_session(@runtime_driver_contract_start_session_opts)

        try do
          assert %SessionHandle{} = session
          assert {:ok, status} = driver.session_status(session)
          assert %ExecutionStatus{} = status
          assert status.scope == :session
        after
          _ = driver.stop_session(session)
        end
      end

      if check_stream_run do
        test "runtime driver contract: stream_run/3 returns run handle and execution events" do
          driver = __runtime_driver_contract_resolve_module__(@runtime_driver_contract_driver)
          request = RunRequest.new!(@runtime_driver_contract_run_request)
          assert {:ok, session} = driver.start_session(@runtime_driver_contract_start_session_opts)

          try do
            assert {:ok, run, stream} = driver.stream_run(session, request, @runtime_driver_contract_run_opts)
            assert %RunHandle{} = run
            assert Enumerable.impl_for(stream) != nil

            events = Enum.take(stream, 100)
            assert Enum.all?(events, &match?(%ExecutionEvent{}, &1))
          after
            _ = driver.stop_session(session)
          end
        end
      end

      if check_run do
        test "runtime driver contract: run/3 returns execution result" do
          driver = __runtime_driver_contract_resolve_module__(@runtime_driver_contract_driver)
          request = RunRequest.new!(@runtime_driver_contract_run_request)
          assert {:ok, session} = driver.start_session(@runtime_driver_contract_start_session_opts)

          try do
            assert {:ok, result} = driver.run(session, request, @runtime_driver_contract_run_opts)
            assert %ExecutionResult{} = result
          after
            _ = driver.stop_session(session)
          end
        end
      end
    end
  end
end
