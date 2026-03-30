defmodule Jido.Harness.ReadmeTest do
  use ExUnit.Case, async: true

  @readme_path Path.expand("../../README.md", __DIR__)

  test "readme keeps boundary metadata carriage explicit and runtime-neutral" do
    readme = @readme_path |> File.read!() |> normalize_whitespace()

    assert readme =~ "boundary-backed",
           "#{@readme_path} must describe boundary-backed runtime carriage"

    assert readme =~ "`metadata[\"boundary\"]`",
           "#{@readme_path} must name the boundary metadata namespace"

    assert readme =~ "does not own sandbox policy",
           "#{@readme_path} must keep sandbox policy ownership outside Harness"
  end

  defp normalize_whitespace(text), do: String.replace(text, ~r/\s+/, " ")
end
