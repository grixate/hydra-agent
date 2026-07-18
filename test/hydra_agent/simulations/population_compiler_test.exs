defmodule HydraAgent.Simulations.PopulationCompilerTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Simulations.{PopulationCompiler, PopulationValidator}

  test "instantiation is exact and deterministic across every supported distribution" do
    contract = contract()

    assert :ok = PopulationValidator.validate(contract)
    assert {:ok, first} = PopulationCompiler.compile(contract)
    assert {:ok, second} = PopulationCompiler.compile(contract)

    assert first.agents == second.agents
    assert first.relationships == second.relationships
    assert first.summary == second.summary
    assert length(first.agents) == 20
    assert first.summary["population_size"] == 20
    assert Enum.sum(Map.values(first.summary["type_counts"])) == 20
    assert first.summary["agent_set_hash"] == second.summary["agent_set_hash"]

    assert Enum.all?(first.representatives, fn representative ->
             representative["prose_generated"] == false and
               representative["generated_lazily"] == true and
               is_list(representative["goals"]) and
               is_list(representative["constraints"]) and
               is_map(representative["state"]) and
               is_map(representative["resources"])
           end)

    assert Enum.all?(first.agents, fn agent ->
             attributes = agent["attributes"]

             attributes["constant_value"] == 0.25 and
               attributes["uniform_value"] >= 0.1 and attributes["uniform_value"] <= 1.0 and
               attributes["normal_value"] >= 0.0 and attributes["normal_value"] <= 1.0 and
               attributes["beta_value"] >= 0.0 and attributes["beta_value"] <= 1.0 and
               attributes["rank"] in 1..5 and is_binary(attributes["segment"]) and
               is_binary(attributes["choice"])
           end)
  end

  test "all V1 topology rules validate and compile deterministically" do
    rules = [
      %{
        "kind" => "none",
        "relationship_type" => "connected",
        "directed" => false,
        "settings" => %{}
      },
      %{
        "kind" => "random",
        "relationship_type" => "connected",
        "directed" => false,
        "settings" => %{"degree" => 2}
      },
      %{
        "kind" => "small_world",
        "relationship_type" => "connected",
        "directed" => false,
        "settings" => %{"degree" => 4, "rewire_probability" => 0.15}
      },
      %{
        "kind" => "hierarchical",
        "relationship_type" => "manages",
        "directed" => true,
        "settings" => %{"manager_ratio" => 0.2}
      },
      %{
        "kind" => "bipartite",
        "relationship_type" => "supplies",
        "directed" => true,
        "settings" => %{"left_type" => "participant", "right_type" => "observer", "degree" => 2}
      },
      %{
        "kind" => "imported",
        "relationship_type" => "knows",
        "directed" => false,
        "settings" => %{}
      }
    ]

    Enum.each(rules, fn rule ->
      candidate = Map.put(contract(), "relationship_rules", [rule])
      assert :ok = PopulationValidator.validate(candidate)
      assert {:ok, first} = PopulationCompiler.compile(candidate)
      assert {:ok, second} = PopulationCompiler.compile(candidate)
      assert first.relationships == second.relationships
    end)
  end

  test "sensitive traits fail closed and consequential individual use is prohibited" do
    unsafe =
      update_in(
        contract(),
        ["agent_types", Access.at(0), "attributes", Access.at(0)],
        fn attribute ->
          attribute |> Map.put("key", "age") |> Map.put("sensitive", false)
        end
      )

    assert {:error, errors} = PopulationValidator.validate(unsafe)
    assert Enum.any?(errors, &(&1["code"] == "sensitive_attribute_not_declared"))

    incomplete =
      update_in(unsafe, ["agent_types", Access.at(0), "attributes", Access.at(0)], fn attribute ->
        Map.put(attribute, "sensitive", true)
      end)

    assert {:error, errors} = PopulationValidator.validate(incomplete)
    assert Enum.any?(errors, &(&1["path"] =~ "lawful_basis"))

    consequential =
      put_in(
        contract(),
        ["generation_metadata", "intended_use"],
        "individual_consequential_recommendation"
      )

    assert {:error, errors} = PopulationValidator.validate(consequential)
    assert Enum.any?(errors, &(&1["code"] == "prohibited_use"))
  end

  test "relationship rules are rejected before they can exceed the compile bound" do
    oversized =
      contract()
      |> Map.put("population_size", 100_000)
      |> put_in(["relationship_rules", Access.at(0), "settings", "degree"], 32)

    assert {:error, errors} = PopulationValidator.validate(oversized)
    assert Enum.any?(errors, &(&1["code"] == "relationship_limit_exceeded"))
  end

  test "normal distributions require explicit bounds" do
    unbounded =
      update_in(
        contract(),
        ["archetypes", Access.at(0), "distributions", "normal_value"],
        &Map.drop(&1, ["min", "max"])
      )

    assert {:error, errors} = PopulationValidator.validate(unbounded)
    assert Enum.any?(errors, &(&1["path"] =~ "normal_value.min"))
    assert Enum.any?(errors, &(&1["path"] =~ "normal_value.max"))
  end

  defp contract do
    attributes = [
      number_attribute("constant_value"),
      number_attribute("uniform_value"),
      number_attribute("normal_value"),
      number_attribute("beta_value"),
      %{"key" => "rank", "type" => "integer", "min" => 1, "max" => 5, "sensitive" => false},
      %{"key" => "segment", "type" => "categorical", "sensitive" => false},
      %{"key" => "choice", "type" => "categorical", "sensitive" => false}
    ]

    types = [
      agent_type("participant", 0.6, attributes),
      agent_type("observer", 0.4, attributes)
    ]

    %{
      "schema_version" => 1,
      "compiler_version" => "hydra-population/v1",
      "seed" => 42,
      "population_size" => 20,
      "agent_types" => types,
      "archetypes" => [archetype("participant"), archetype("observer")],
      "conditional_distributions" => [
        %{
          "when" => %{"attribute" => "rank", "operator" => "gte", "value" => 4},
          "set" => %{"uniform_value" => %{"kind" => "uniform", "min" => 0.6, "max" => 1.0}}
        }
      ],
      "relationship_rules" => [
        %{
          "kind" => "small_world",
          "relationship_type" => "connected",
          "directed" => false,
          "settings" => %{"degree" => 4, "rewire_probability" => 0.1}
        }
      ],
      "representative_rules" => %{"per_archetype" => 1, "high_influence" => 1, "outliers" => 1},
      "imported_agents" => [],
      "imported_relationships" => [],
      "import_summary" => %{},
      "compile_summary" => %{},
      "generation_metadata" => %{"intended_use" => "aggregate_simulation"},
      "status" => "ready"
    }
  end

  defp number_attribute(key) do
    %{"key" => key, "type" => "number", "min" => 0.0, "max" => 1.0, "sensitive" => false}
  end

  defp agent_type(id, weight, attributes) do
    %{
      "id" => id,
      "label" => String.capitalize(id),
      "description" => "A bounded #{id} type.",
      "weight" => weight,
      "attributes" => attributes,
      "resources" => ["time"],
      "actions" => ["wait", "act"],
      "grounding" => ["claim_1"]
    }
  end

  defp archetype(type_id) do
    %{
      "id" => "steady_#{type_id}",
      "agent_type" => type_id,
      "weight" => 1.0,
      "summary" => "A steady #{type_id} archetype.",
      "distributions" => %{
        "constant_value" => %{"kind" => "constant", "value" => 0.25},
        "uniform_value" => %{"kind" => "uniform", "min" => 0.1, "max" => 0.9},
        "normal_value" => %{
          "kind" => "normal",
          "mean" => 0.5,
          "sd" => 0.2,
          "min" => 0.0,
          "max" => 1.0
        },
        "beta_value" => %{
          "kind" => "beta",
          "alpha" => 2.0,
          "beta" => 3.0,
          "min" => 0.0,
          "max" => 1.0
        },
        "rank" => %{"kind" => "integer_range", "min" => 1, "max" => 5},
        "segment" => %{"kind" => "categorical", "values" => %{"core" => 0.7, "edge" => 0.3}},
        "choice" => %{
          "kind" => "weighted_list",
          "values" => [
            %{"value" => "wait", "weight" => 0.4},
            %{"value" => "act", "weight" => 0.6}
          ]
        }
      },
      "goals" => ["reach a bounded outcome"],
      "constraints" => ["limited time"],
      "initial_state" => %{"phase" => "ready"},
      "initial_resources" => %{"time" => 0.5},
      "policy_id" => "#{type_id}_policy",
      "memory_seeds" => ["The test begins from a bounded state."],
      "grounding" => ["claim_1"]
    }
  end
end
