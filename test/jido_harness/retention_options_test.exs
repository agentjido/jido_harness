defmodule Jido.Harness.RetentionOptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{ProcessSpec, SessionRequest}

  test "normalizes string keys for process and session retention" do
    assert {:ok, process} =
             ProcessSpec.new(%{
               executable: "/bin/echo",
               retention: %{"memory_bytes" => 1_024, "segment_bytes" => 2_048, "disk_limit_bytes" => 4_096}
             })

    assert process.retention == %{memory_bytes: 1_024, segment_bytes: 2_048, disk_limit_bytes: 4_096}

    assert {:ok, session} = SessionRequest.new(%{retention: %{"journal_dir" => "/tmp", "memory_bytes" => 512}})
    assert session.retention == %{journal_dir: "/tmp", memory_bytes: 512}
  end

  test "rejects unknown, invalid, and internally inconsistent retention options" do
    assert {:error, %Jido.Harness.Error{message: "unknown retention option"}} =
             SessionRequest.new(%{retention: %{unknown: true}})

    assert {:error, %Jido.Harness.Error{details: %{field: :memory_bytes}}} =
             ProcessSpec.new(%{executable: "/bin/echo", retention: %{memory_bytes: 0}})

    assert {:error, %Jido.Harness.Error{message: "retention segment_bytes cannot exceed disk_limit_bytes"}} =
             SessionRequest.new(%{retention: %{segment_bytes: 2_048, disk_limit_bytes: 1_024}})
  end
end
