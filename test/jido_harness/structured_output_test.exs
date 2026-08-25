defmodule Jido.Harness.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.{Error, JSONSchema, RequestResolver, RunRequest, StructuredOutput}

  @schema %{
    "type" => "object",
    "properties" => %{
      "department" => %{"type" => "string", "enum" => ["people", "finance"]},
      "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
    },
    "required" => ["department", "confidence"],
    "additionalProperties" => false
  }

  test "admits the bounded request type but rejects it for current ACP profiles" do
    attrs = %{prompt: "classify", structured_output: %{schema_id: "hr.classification.v1", schema: @schema}}

    assert {:ok, %RunRequest{structured_output: %StructuredOutput{} = output}} =
             RunRequest.new(attrs)

    assert output.schema_id == "hr.classification.v1"
    assert output.max_output_bytes == 262_144

    for provider <- [:codex, :amp] do
      assert {:error, %Error{category: :validation, details: %{field: :structured_output}}} =
               RequestResolver.resolve(provider, attrs)
    end
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
end
