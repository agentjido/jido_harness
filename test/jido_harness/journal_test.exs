defmodule Jido.Harness.JournalTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Journal

  test "rotates bounded disk segments and reports a cursor replay gap" do
    base = Path.join(System.tmp_dir!(), "jido-harness-journal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, journal} =
             Journal.open("rotation", %{
               journal_dir: base,
               segment_bytes: 180,
               disk_limit_bytes: 420
             })

    journal =
      Enum.reduce(1..20, journal, fn sequence, journal ->
        assert {:ok, journal} =
                 Journal.append(journal, %{
                   sequence: sequence,
                   payload: String.duplicate("x", 80)
                 })

        journal
      end)

    assert journal.total_bytes <= journal.disk_limit_bytes
    assert journal.available_from > 1
    {records, _journal} = Journal.replay(journal, 0, 100)
    assert [%{"sequence" => first} | _] = records
    assert first == journal.available_from
  end

  test "returns an error when the secure journal directory cannot be created" do
    file = Path.join(System.tmp_dir!(), "jido-harness-journal-file-#{System.unique_integer([:positive])}")
    File.write!(file, "not a directory")
    on_exit(fn -> File.rm(file) end)

    assert {:error, _reason} = Journal.open("failure", %{journal_dir: file})
  end
end
