defmodule Jido.Harness.AdapterContract do
  @moduledoc """
  Shared contract tests for provider adapter packages.

  ## Usage

      defmodule MyAdapterTest do
        use ExUnit.Case, async: false
        use Jido.Harness.AdapterContract,
          adapter: My.Adapter,
          provider: :my_provider,
          check_run: true,
          run_request: %{prompt: "hello", metadata: %{}}
      end
  """

  defmacro __using__(opts) do
    quote do
      import Jido.Harness.AdapterContract
      adapter_contract(unquote(opts))
    end
  end

  defmacro adapter_contract(opts) do
    adapter = opts |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)
    provider = Keyword.get(opts, :provider)
    check_run = Keyword.get(opts, :check_run, false)
    run_request = Keyword.get(opts, :run_request, %{prompt: "contract smoke", metadata: %{}})
    run_opts = Keyword.get(opts, :run_opts, [])

    quote bind_quoted: [
            adapter: adapter,
            provider: provider,
            check_run: check_run,
            run_request: run_request,
            run_opts: run_opts
          ] do
      alias Jido.Harness.{Event, RunRequest, RuntimeContract}
      @adapter_contract_adapter adapter
      @adapter_contract_provider provider
      @adapter_contract_run_request run_request
      @adapter_contract_run_opts run_opts

      defp __adapter_contract_resolve_module__(value) when is_atom(value), do: value

      test "adapter contract: id/0 returns atom" do
        adapter = __adapter_contract_resolve_module__(@adapter_contract_adapter)
        assert Code.ensure_loaded?(adapter), "adapter module could not be loaded: #{inspect(adapter)}"
        assert function_exported?(adapter, :id, 0), "adapter module not loaded: #{inspect(adapter)}"
        id = adapter.id()
        assert is_atom(id)

        if is_atom(@adapter_contract_provider) do
          assert id == @adapter_contract_provider
        end
      end

      test "adapter contract: capabilities/0 returns capability struct" do
        adapter = __adapter_contract_resolve_module__(@adapter_contract_adapter)
        assert Code.ensure_loaded?(adapter)
        assert function_exported?(adapter, :capabilities, 0)

        caps = adapter.capabilities()
        assert %Jido.Harness.Capabilities{} = caps

        for key <- [
              :streaming?,
              :tool_calls?,
              :tool_results?,
              :thinking?,
              :resume?,
              :usage?,
              :file_changes?,
              :cancellation?
            ] do
          assert is_boolean(Map.get(caps, key))
        end
      end

      test "adapter contract: runtime_contract/0 is complete" do
        adapter = __adapter_contract_resolve_module__(@adapter_contract_adapter)
        assert Code.ensure_loaded?(adapter)
        assert function_exported?(adapter, :runtime_contract, 0)
        contract = apply(adapter, :runtime_contract, [])
        assert %RuntimeContract{} = contract
        assert is_atom(contract.provider)
        assert is_list(contract.runtime_tools_required)
        assert is_list(contract.compatibility_probes)
        assert is_list(contract.install_steps)
        assert is_list(contract.auth_bootstrap_steps)
        assert is_binary(contract.triage_command_template)
        assert is_binary(contract.coding_command_template)
        assert is_list(contract.success_markers)
      end

      if check_run do
        test "adapter contract: run/2 returns enumerable of normalized events" do
          adapter = __adapter_contract_resolve_module__(@adapter_contract_adapter)
          assert Code.ensure_loaded?(adapter)
          request = RunRequest.new!(@adapter_contract_run_request)
          assert {:ok, stream} = adapter.run(request, @adapter_contract_run_opts)
          assert Enumerable.impl_for(stream) != nil

          events =
            stream
            |> Enum.take(100)

          assert Enum.all?(events, &match?(%Event{}, &1))
        end
      end
    end
  end
end
