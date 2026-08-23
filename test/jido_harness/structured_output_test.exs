defmodule Jido.Harness.StructuredOutputTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Jido.Harness.{Error, JSONSchema, RequestResolver, RunRequest, StructuredOutput}
  alias Jido.Harness.StructuredOutput.SchemaWorkspace

  @schema %{
    "type" => "object",
    "properties" => %{
      "department" => %{"type" => "string", "enum" => ["people", "finance"]},
      "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
    },
    "required" => ["department", "confidence"],
    "additionalProperties" => false
  }

  test "admits a bounded normalized contract only for capable providers" do
    attrs = %{prompt: "classify", structured_output: %{schema_id: "hr.classification.v1", schema: @schema}}

    assert {:ok, %RunRequest{structured_output: %StructuredOutput{} = output}} =
             RequestResolver.resolve(:codex, attrs)

    assert output.schema_id == "hr.classification.v1"
    assert output.max_output_bytes == 262_144

    assert {:error, %Error{category: :validation, details: %{field: :structured_output}}} =
             RequestResolver.resolve(:amp, attrs)
  end

  test "rejects invalid identifiers, output bounds, keywords, depth, and aggregate property counts" do
    assert {:error, %Error{details: %{failure_kind: :invalid_schema_id}}} =
             RunRequest.new(prompt: "x", structured_output: %{schema_id: "bad id", schema: @schema})

    assert {:error, %Error{details: %{failure_kind: :invalid_output_limit}}} =
             RunRequest.new(
               prompt: "x",
               structured_output: %{schema_id: "valid", schema: @schema, max_output_bytes: 1_048_577}
             )

    assert {:error, %Error{details: %{failure_kind: :unsupported_schema_keyword}}} =
             JSONSchema.admit(%{"type" => "string", "pattern" => "private-value"})

    too_deep =
      Enum.reduce(1..17, %{"type" => "string"}, fn _index, child ->
        %{"type" => "array", "items" => child}
      end)

    assert {:error, %Error{details: %{failure_kind: :schema_too_deep}}} = JSONSchema.admit(too_deep)

    properties = Map.new(1..257, &{"field_#{&1}", %{"type" => "string"}})

    assert {:error, %Error{details: %{failure_kind: :too_many_schema_properties}}} =
             JSONSchema.admit(%{"type" => "object", "properties" => properties})
  end

  test "admits the governed 128-concept schema within the bounded aggregate enum ceiling" do
    concepts = Enum.map(1..128, &"concept-#{&1}")

    schema = %{
      "type" => "object",
      "properties" => %{
        "disposition" => %{"type" => "string", "enum" => ~w(classified insufficient ambiguous)},
        "concept_id" => %{"type" => "string", "enum" => concepts}
      },
      "required" => ~w(disposition concept_id),
      "additionalProperties" => false
    }

    assert :ok = JSONSchema.admit(schema)

    too_many = %{"type" => "string", "enum" => Enum.map(1..257, &"value-#{&1}")}
    assert {:error, %Error{details: %{failure_kind: :too_many_schema_enum_values}}} = JSONSchema.admit(too_many)
  end

  test "rejects schema combinators before provider execution" do
    schema = %{
      "anyOf" => [
        %{"type" => "string"},
        %{"type" => "null"}
      ]
    }

    assert {:error, %Error{details: %{failure_kind: :unsupported_schema_keyword}}} =
             JSONSchema.admit(schema)
  end

  test "serializes schemas deterministically in an owner-only workspace and removes it" do
    base = Path.join(System.tmp_dir!(), "jido-harness-schema-test-#{System.unique_integer([:positive])}")
    output = StructuredOutput.new!(schema_id: "hr.v1", schema: @schema)

    on_exit(fn -> File.rm_rf(base) end)

    assert {:ok, expected} = JSONSchema.encode(@schema)
    assert {:ok, workspace} = SchemaWorkspace.open(output, base_directory: base)
    assert File.read!(workspace.schema_path) == expected
    assert permissions(workspace.directory) == 0o700
    assert permissions(workspace.schema_path) == 0o600
    assert :ok = SchemaWorkspace.close(workspace)
    refute File.exists?(workspace.directory)
  end

  test "uses unique workspaces and cleans up when the consumer raises" do
    base = Path.join(System.tmp_dir!(), "jido-harness-schema-test-#{System.unique_integer([:positive])}")
    output = StructuredOutput.new!(schema_id: "hr.v1", schema: @schema)
    parent = self()

    on_exit(fn -> File.rm_rf(base) end)

    assert {:ok, first} = SchemaWorkspace.open(output, base_directory: base)
    assert {:ok, second} = SchemaWorkspace.open(output, base_directory: base)
    refute first.directory == second.directory
    assert :ok = SchemaWorkspace.close(first)
    assert :ok = SchemaWorkspace.close(second)

    assert_raise RuntimeError, "consumer stopped", fn ->
      SchemaWorkspace.with_open(
        output,
        fn workspace ->
          send(parent, {:workspace, workspace.directory})
          raise "consumer stopped"
        end,
        base_directory: base
      )
    end

    assert_receive {:workspace, directory}
    refute File.exists?(directory)
  end

  test "staging failures do not disclose schema data or paths" do
    secret = "employee-secret-value"
    output = StructuredOutput.new!(schema_id: "hr.v1", schema: %{"type" => "string", "const" => secret})
    blocking_file = Path.join(System.tmp_dir!(), "schema-block-#{System.unique_integer([:positive])}")
    blocked_base = Path.join(blocking_file, "blocked")
    File.write!(blocking_file, "block")
    on_exit(fn -> File.rm(blocking_file) end)

    assert {:error, %Error{} = error} = SchemaWorkspace.open(output, base_directory: blocked_base)
    rendered = inspect(error)
    refute rendered =~ secret
    refute rendered =~ blocked_base
  end

  defp permissions(path) do
    {:ok, stat} = File.stat(path)
    band(stat.mode, 0o777)
  end
end
