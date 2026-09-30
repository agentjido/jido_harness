defmodule Jido.Harness.NativeRuntimeTest do
  use ExUnit.Case, async: false

  import Jido.Harness.TestHelpers

  unless :os.type() in [{:unix, :darwin}, {:unix, :linux}] do
    @moduletag skip: "native fault injection requires macOS or Linux"
  end

  setup do
    directory = Path.join(System.tmp_dir!(), "harness-native-group-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    library = Path.join(directory, "group_failure.so")
    wrapper = Path.join(directory, "port_wrapper")

    {flags, loader} =
      case :os.type() do
        {:unix, :darwin} -> {["-dynamiclib", "-fPIC"], "DYLD_INSERT_LIBRARIES"}
        {:unix, :linux} -> {["-shared", "-fPIC", "-ldl"], "LD_PRELOAD"}
      end

    assert {_output, 0} =
             System.cmd("cc", ["-o", library, fixture_path("process_groups/group_failure.c")] ++ flags,
               stderr_to_stdout: true
             )

    assert {_output, 0} =
             System.cmd("cc", ["-O2", "-o", wrapper, fixture_path("process_groups/port_wrapper.c")],
               stderr_to_stdout: true
             )

    %{library: library, wrapper: wrapper, loader: loader}
  end

  test "a forced child group error is accepted only after the parent assigned the requested group", context do
    assert {output, 0} = run_vm(context, false)
    assert output =~ "GROUP_CHECK_OK"
  end

  test "a forced group error prevents the command from running when both assignments fail", context do
    assert {output, 0} = run_vm(context, true)
    assert output =~ "GROUP_CHECK_OK"
  end

  defp run_vm(context, deny_parent) do
    architecture = :erlang.system_info(:system_architecture) |> to_string()
    helper = Path.join([to_string(:code.priv_dir(:jido_harness)), "native", architecture, "exec-port"])

    environment = [
      {~c"ERLEXEC_TEST_PORT", String.to_charlist(helper)},
      {~c"ERLEXEC_TEST_LIBRARY", String.to_charlist(context.library)},
      {~c"ERLEXEC_TEST_LOADER", String.to_charlist(context.loader)}
    ]

    environment = if deny_parent, do: [{~c"ERLEXEC_TEST_DENY_PARENT_GROUP", ~c"1"} | environment], else: environment

    expected =
      if deny_parent do
        """
        {error, Details} ->
          256 = proplists:get_value(exit_status, Details),
          undefined = proplists:get_value(stdout, Details),
          [<<"Cannot set effective group to 0", _/binary>>] = proplists:get_value(stderr, Details)
        """
      else
        ~S({ok, [{stdout, [<<"group-ok\n">>]}]} -> ok)
      end

    expression = """
    {ok, _} = jido_harness_exec:start([{portexe, #{literal(String.to_charlist(context.wrapper))}},
                                     {env, #{literal(environment)}}]),
    case jido_harness_exec:run(["/bin/echo", "group-ok"],
      [sync, stdout, stderr, {group, 0}, kill_group,
       {env, [{#{literal(String.to_charlist(context.loader))}, false}]}]) of
      #{expected};
      Other -> io:format("Unexpected result: ~p~n", [Other]), halt(1)
    end,
    io:format("GROUP_CHECK_OK~n"), halt(0).
    """

    ebin = :code.lib_dir(:jido_harness) |> to_string() |> Path.join("ebin")

    System.cmd("erl", ["-pa", ebin, "-noshell", "-eval", expression],
      stderr_to_stdout: true,
      env: [{"ERL_CRASH_DUMP", Path.join(Path.dirname(context.wrapper), "erl_crash.dump")}]
    )
  end

  defp literal(value), do: :io_lib.format(~c"~tp", [value]) |> IO.iodata_to_binary()
end
