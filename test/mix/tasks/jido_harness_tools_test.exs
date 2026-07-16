defmodule Mix.Tasks.JidoHarness.ToolsTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.CLIInventory
  alias Mix.Tasks.JidoHarness.Tools

  test "selects tools in requested order and rejects unknown names" do
    entries = CLIInventory.entries()

    assert Enum.map(Tools.select_tools("goose,claude,goose", entries), & &1.id) == [
             :goose,
             :claude
           ]

    assert_raise Mix.Error, ~r/unknown tools: invented/, fn ->
      Tools.select_tools("invented", entries)
    end
  end

  test "strict inventory accepts current, newer, and self-updating versions" do
    rows = [
      row(:current, :current),
      row(:newer, :newer),
      row(:self_updating, :latest),
      row(:old, :outdated),
      row(:missing, :missing)
    ]

    assert Enum.map(Tools.strict_failures(rows), & &1.entry.id) == [:old, :missing]
  end

  defp row(id, status), do: %{entry: %{id: id}, result: %{version_status: status}}
end
