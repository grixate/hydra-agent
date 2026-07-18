defmodule HydraAgent.Simulations.ScriptValidatorTest do
  use HydraAgent.DataCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Simulations.{
    Blueprints,
    ScriptBuilder,
    ScriptExporter,
    ScriptPreviewEngine,
    ScriptValidator
  }

  setup do
    workspace =
      workspace_fixture(%{
        name: "Script Studio",
        slug: "script-studio-#{System.unique_integer([:positive])}"
      })

    [general, _decision_replay] = Blueprints.ensure_builtins!()

    {:ok, simulation} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a clear service change affect adoption over six weeks?",
        "blueprint_id" => general.id,
        "locale" => "en",
        "execution_mode" => "quick",
        "population_size" => 20,
        "horizon" => "6 weeks"
      })

    %{simulation: simulation, script: simulation.active_script.script}
  end

  test "provider-free scripts cover V1 sections and preview deterministically", %{
    simulation: simulation,
    script: script
  } do
    assert Map.keys(script) |> Enum.sort() ==
             ~w(actions agent_types clock events hydra_simulation_script metadata observations perception policies relationships resources stopping_conditions transitions world)
             |> Enum.sort()

    assert script["clock"] == %{"kind" => "rounds", "count" => 6, "label" => "week"}
    assert simulation.active_script.status == "ready"
    assert simulation.active_script.validation_report["arbitrary_code"] == false
    assert simulation.active_script.preview.status == "passed"
    assert simulation.active_script.preview.rounds_completed == 2
    assert simulation.active_script.preview.summary["model_calls"] == 0

    assert {:ok, first} = ScriptPreviewEngine.run(script, simulation.active_population_model)
    assert {:ok, second} = ScriptPreviewEngine.run(script, simulation.active_population_model)
    assert first.result_hash == second.result_hash
    assert first.summary == second.summary
  end

  test "missing references, impossible costs, and executable expression nodes fail closed", %{
    simulation: simulation,
    script: script
  } do
    unknown_actor = put_in(script, ["actions", Access.at(0), "actors"], ["undeclared_type"])

    assert {:error, actor_errors} =
             ScriptValidator.validate(unknown_actor, simulation.active_population_model)

    assert Enum.any?(actor_errors, &(&1["code"] == "unknown_reference"))

    [resource | _] = script["resources"]

    impossible_cost =
      put_in(script, ["actions", Access.at(0), "costs"], [
        %{"resource" => resource["id"], "amount" => 2.0}
      ])

    assert {:error, cost_errors} =
             ScriptValidator.validate(impossible_cost, simulation.active_population_model)

    assert Enum.any?(cost_errors, &(&1["code"] == "negative_balance_possible"))

    consumption_forbidden =
      impossible_cost
      |> put_in(["resources", Access.at(0), "burn_allowed"], false)
      |> put_in(["actions", Access.at(0), "costs", Access.at(0), "amount"], 0.1)

    assert {:error, permission_errors} =
             ScriptValidator.validate(consumption_forbidden, simulation.active_population_model)

    assert Enum.any?(permission_errors, &(&1["code"] == "burn_not_allowed"))

    executable =
      put_in(
        script,
        [
          "policies",
          Access.at(0),
          "candidates",
          hd(Map.keys(hd(script["policies"])["candidates"]))
        ],
        %{"eval" => "System.cmd('sh', [])"}
      )

    assert {:error, expression_errors} =
             ScriptValidator.validate(executable, simulation.active_population_model)

    assert Enum.any?(expression_errors, &(&1["code"] == "unsupported_expression"))

    undeclared_state =
      put_in(script, ["actions", Access.at(0), "effects", Access.at(0), "path"], "state.shell")

    assert {:error, path_errors} =
             ScriptValidator.validate(undeclared_state, simulation.active_population_model)

    assert Enum.any?(path_errors, &(&1["code"] == "missing_reference"))

    unknown_world_resource = put_in(script, ["world", "resources"], %{"ghost" => 1})

    assert {:error, world_resource_errors} =
             ScriptValidator.validate(unknown_world_resource, simulation.active_population_model)

    assert Enum.any?(world_resource_errors, fn error ->
             error["path"] == "$.world.resources.ghost" and
               error["code"] == "missing_reference"
           end)
  end

  test "hybrid cognition requires a model budget and transition emissions cannot cycle", %{
    simulation: simulation,
    script: script
  } do
    [first_policy | rest] = script["policies"]

    hybrid = %{
      "id" => first_policy["id"],
      "kind" => "hybrid",
      "fallback" => "deterministic_fallback",
      "candidates" => Map.keys(first_policy["candidates"]),
      "escalate_when" => %{
        "fact" => "decision.uncertainty",
        "op" => "gte",
        "value" => 0.5
      },
      "model_role" => "simulation"
    }

    fallback =
      first_policy
      |> Map.put("id", "deterministic_fallback")

    script =
      script
      |> put_in(["policies"], [hybrid, fallback | rest])
      |> update_in(["agent_types"], fn [first | other] ->
        [Map.put(first, "policy", hybrid["id"]) | other]
      end)

    assert {:error, budget_errors} =
             ScriptValidator.validate(script, simulation.active_population_model)

    assert Enum.any?(budget_errors, &(&1["code"] == "model_budget_required"))

    assert {:ok, _report} =
             ScriptValidator.validate(script, simulation.active_population_model,
               model_budget?: true
             )

    cyclic =
      put_in(script, ["transitions"], [
        %{
          "id" => "first_cycle",
          "when" => %{"event_type" => "simulation_begins"},
          "target" => %{"audience" => true},
          "effects" => [],
          "emits" => [%{"type" => "second_cycle", "payload" => %{}}]
        },
        %{
          "id" => "second_cycle",
          "when" => %{"event_type" => "second_cycle"},
          "target" => %{"audience" => true},
          "effects" => [],
          "emits" => [%{"type" => "simulation_begins", "payload" => %{}}]
        }
      ])

    assert {:error, cycle_errors} =
             ScriptValidator.validate(cyclic, simulation.active_population_model,
               model_budget?: true
             )

    assert Enum.any?(cycle_errors, &(&1["code"] == "unbounded_event_cycle"))
  end

  test "relationship effects require numeric weights and bounded neighbor targets", %{
    simulation: simulation,
    script: script
  } do
    [relationship | _] = script["relationships"]

    invalid_weight =
      update_in(script, ["actions", Access.at(0), "effects"], fn effects ->
        effects ++
          [
            %{
              "op" => "set_relationship",
              "relationship" => relationship["id"],
              "target" => %{"self" => true},
              "value" => "strong"
            }
          ]
      end)

    assert {:error, weight_errors} =
             ScriptValidator.validate(invalid_weight, simulation.active_population_model)

    assert Enum.any?(weight_errors, &(&1["code"] == "invalid_expression"))

    unbounded_target =
      put_in(
        script,
        ["actions", Access.at(0), "effects", Access.at(0), "target"],
        %{"relationship_neighbors" => %{"type" => relationship["id"]}}
      )

    assert {:error, target_errors} =
             ScriptValidator.validate(unbounded_target, simulation.active_population_model)

    assert Enum.any?(target_errors, &(&1["path"] =~ "relationship_neighbors.limit"))

    scheduled_relationship_effect =
      update_in(script, ["events", Access.at(0), "effects"], fn effects ->
        effects ++
          [
            %{
              "op" => "adjust_relationship",
              "relationship" => relationship["id"],
              "target" => %{"audience" => true},
              "value" => -0.05
            }
          ]
      end)

    assert {:ok, _report} =
             ScriptValidator.validate(
               scheduled_relationship_effect,
               simulation.active_population_model
             )

    action_event_transition =
      put_in(script, ["transitions"], [
        %{
          "id" => "after_action",
          "when" => %{"event_type" => "action_selected"},
          "target" => %{"audience" => true},
          "effects" => [],
          "emits" => []
        }
      ])

    assert {:ok, _report} =
             ScriptValidator.validate(action_event_transition, simulation.active_population_model)
  end

  test "repair is attempted once and failed previews return safe blockers", %{
    simulation: simulation,
    script: script
  } do
    invalid = put_in(script, ["clock", "kind"], "continuous")
    Process.put(:repair_calls, 0)

    repair = fn _candidate, _errors ->
      Process.put(:repair_calls, Process.get(:repair_calls) + 1)
      invalid
    end

    assert {:error, %{repair_attempts: 1}} =
             ScriptBuilder.validate_with_repair(
               invalid,
               simulation.active_population_model,
               repair
             )

    assert Process.get(:repair_calls) == 1

    population = simulation.active_population_model
    representative = population.compile_summary["representatives"] |> hd()

    population =
      put_in(
        population.compile_summary["representatives"],
        [Map.put(representative, "resources", %{})]
      )

    [resource | _] = script["resources"]

    costly =
      put_in(script, ["actions", Access.at(0), "costs"], [
        %{"resource" => resource["id"], "amount" => 0.1}
      ])

    assert {:error, preview} = ScriptPreviewEngine.run(costly, population)
    assert preview.status == "failed"
    assert preview.rounds_completed == 0

    assert preview.errors == [
             %{
               "path" => "$",
               "code" => "insufficient_resource",
               "message" => "a representative agent cannot satisfy a declared action cost"
             }
           ]
  end

  test "JSON and YAML exports preserve the canonical script", %{script: script} do
    assert {:ok, decoded_json} = script |> ScriptExporter.json() |> Jason.decode()
    assert decoded_json == script

    assert {:ok, decoded_yaml} = script |> ScriptExporter.yaml() |> YamlElixir.read_from_string()
    assert decoded_yaml == script
  end
end
