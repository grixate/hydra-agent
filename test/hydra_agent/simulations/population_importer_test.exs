defmodule HydraAgent.Simulations.PopulationImporterTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Simulations.PopulationImporter

  test "CSV agents keep valid rows and report invalid rows without raw values" do
    csv = """
    id,type,attribute_score,attribute_note,resource_budget,state_phase
    agent-1,participant,0.72,"careful, but open",10,ready
    invalid id,participant,private-raw-value,do-not-echo,4,ready
    """

    assert {:ok, imported} = PopulationImporter.import("agents.csv", csv)
    assert imported.kind == :agents
    assert length(imported.agents) == 1
    assert imported.summary["valid_count"] == 1
    assert imported.summary["error_count"] == 1
    refute inspect(imported.summary["errors"]) =~ "private-raw-value"
    refute inspect(imported.summary["errors"]) =~ "do-not-echo"

    [agent] = imported.agents
    assert String.starts_with?(agent["id"], "source-")
    refute agent["id"] == "agent-1"
    assert agent["attributes"]["score"] == 0.72
    assert agent["attributes"]["note"] == "careful, but open"
    assert agent["resources"]["budget"] == 10
    assert agent["initial_state"]["phase"] == "ready"
  end

  test "CSV sensitive attributes require an explicit Population Model contract" do
    csv = "id,type,attribute_age\nagent-1,participant,42\n"

    assert {:ok, imported} = PopulationImporter.import("agents.csv", csv)
    assert imported.agents == []
    assert imported.summary["error_count"] == 1

    assert [error] = imported.summary["errors"]
    assert error["code"] == "sensitive_attribute_requires_model_metadata"
  end

  test "duplicate agent identifiers reject the later row with its row number" do
    csv = "id,type\nagent-1,participant\nagent-1,participant\n"

    assert {:ok, imported} = PopulationImporter.import("agents.csv", csv)
    assert length(imported.agents) == 1
    assert imported.summary["error_count"] == 1

    assert [error] = imported.summary["errors"]
    assert error["row"] == 3
    assert error["field"] == "id"
    assert error["code"] == "duplicate_identifier"
  end

  test "relationship CSV supports explicit column mapping and row-level validation" do
    csv = "from,to,edge,strength,one_way\na,b,trusts,0.8,true\na,c,trusts,invalid,false\n"

    params = %{
      "kind" => "relationships",
      "source_column" => "from",
      "target_column" => "to",
      "relationship_type_column" => "edge",
      "weight_column" => "strength",
      "directed_column" => "one_way"
    }

    assert {:ok, imported} = PopulationImporter.import("edges.csv", csv, params)
    assert imported.kind == :relationships
    assert length(imported.relationships) == 1
    assert imported.summary["valid_count"] == 1
    assert imported.summary["error_count"] == 1
    assert hd(imported.summary["errors"])["code"] == "invalid_weight"

    [relationship] = imported.relationships
    assert String.starts_with?(relationship["source"], "source-")
    assert String.starts_with?(relationship["target"], "source-")
  end

  test "JSON Population Models are semantically validated before persistence" do
    model =
      sample_model()
      |> Map.put("hydra_population_model", 1)
      |> Jason.encode!()

    assert {:ok, imported} = PopulationImporter.import("population.json", model)
    assert imported.kind == :population_model
    assert imported.summary["valid_count"] == 1
    assert imported.population_model["population_size"] == 10

    unsafe =
      sample_model()
      |> put_in(
        ["generation_metadata", "intended_use"],
        "individual_consequential_recommendation"
      )
      |> Map.put("hydra_population_model", 1)
      |> Jason.encode!()

    assert {:ok, rejected} = PopulationImporter.import("unsafe.json", unsafe)
    assert rejected.population_model == nil
    assert rejected.summary["valid_count"] == 0
    assert rejected.summary["error_count"] > 0
  end

  test "row bounds reject overflow instead of silently truncating input" do
    rows = Enum.map_join(1..10_001, "\n", &"agent-#{&1},participant")
    csv = "id,type\n#{rows}\n"

    assert {:error, :population_import_too_many_rows} =
             PopulationImporter.import("agents.csv", csv)
  end

  test "malformed optional contract sections return validation errors instead of crashing" do
    malformed =
      sample_model()
      |> Map.put("hydra_population_model", 1)
      |> Map.put("imported_agents", %{"unexpected" => true})
      |> Map.put("generation_metadata", "invalid")
      |> Jason.encode!()

    assert {:ok, rejected} = PopulationImporter.import("malformed.json", malformed)
    assert rejected.population_model == nil

    codes = MapSet.new(rejected.summary["errors"], & &1["code"])
    assert MapSet.member?(codes, "invalid_array")
    assert MapSet.member?(codes, "invalid_object")
  end

  defp sample_model do
    %{
      "schema_version" => 1,
      "compiler_version" => "hydra-population/v1",
      "seed" => 7,
      "population_size" => 10,
      "agent_types" => [
        %{
          "id" => "participant",
          "label" => "Participant",
          "description" => "A bounded participant role.",
          "weight" => 1.0,
          "attributes" => [
            %{
              "key" => "signal",
              "type" => "number",
              "min" => 0.0,
              "max" => 1.0,
              "sensitive" => false
            }
          ],
          "resources" => ["time"],
          "actions" => ["wait"],
          "grounding" => ["claim_1"]
        }
      ],
      "archetypes" => [
        %{
          "id" => "steady_participant",
          "agent_type" => "participant",
          "weight" => 1.0,
          "summary" => "A steady participant.",
          "distributions" => %{"signal" => %{"kind" => "constant", "value" => 0.5}},
          "goals" => ["remain steady"],
          "constraints" => [],
          "initial_state" => %{},
          "initial_resources" => %{"time" => 1.0},
          "policy_id" => "participant_policy",
          "memory_seeds" => [],
          "grounding" => ["claim_1"]
        }
      ],
      "conditional_distributions" => [],
      "relationship_rules" => [],
      "representative_rules" => %{"per_archetype" => 1, "high_influence" => 0, "outliers" => 0},
      "imported_agents" => [],
      "imported_relationships" => [],
      "import_summary" => %{},
      "compile_summary" => %{},
      "generation_metadata" => %{"intended_use" => "aggregate_simulation"},
      "status" => "ready"
    }
  end
end
