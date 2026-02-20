defmodule Jido.Harness.Exec.ResultTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Exec.Result

  test "stream_success?/3 matches custom marker fields" do
    markers = [%{"type" => "result", "status" => "success"}]

    assert Result.stream_success?(:gemini, [%{"type" => "result", "status" => "success"}], markers)
    refute Result.stream_success?(:gemini, [%{"type" => "result", "status" => "failure"}], markers)
    refute Result.stream_success?(:gemini, [%{"type" => "result"}], markers)
  end

  test "stream_success?/3 respects is_error_false marker constraint" do
    markers = [%{"type" => "result", "is_error_false" => true}]

    assert Result.stream_success?(:claude, [%{"type" => "result", "is_error" => false}], markers)
    assert Result.stream_success?(:claude, [%{"type" => "result"}], markers)
    refute Result.stream_success?(:claude, [%{"type" => "result", "is_error" => true}], markers)
  end
end
