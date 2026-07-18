defmodule HydraAgent.Simulations.JsonSchemaTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Simulations.JsonSchema

  test "validates the bounded object, array, number, and local-reference subset" do
    schema = %{
      "type" => "object",
      "required" => ["items"],
      "additionalProperties" => false,
      "properties" => %{
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{"$ref" => "#/$defs/item"}
        }
      },
      "$defs" => %{
        "item" => %{
          "type" => "object",
          "required" => ["score"],
          "properties" => %{"score" => %{"type" => "number", "minimum" => 0, "maximum" => 1}}
        }
      }
    }

    assert :ok = JsonSchema.validate(schema, %{"items" => [%{"score" => 0.5}]})

    assert {:error, errors} =
             JsonSchema.validate(schema, %{"items" => [%{"score" => 2}], "unknown" => true})

    assert Enum.any?(errors, &(&1["path"] == "$.items[0].score"))
    assert Enum.any?(errors, &(&1["path"] == "$.unknown"))
  end

  test "fails closed on an unresolved reference" do
    assert {:error, [%{"message" => "schema reference could not be resolved"}]} =
             JsonSchema.validate(%{"$ref" => "#/missing"}, %{})
  end
end
