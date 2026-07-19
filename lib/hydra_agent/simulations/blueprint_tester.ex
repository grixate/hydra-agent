defmodule HydraAgent.Simulations.BlueprintTester do
  @moduledoc "Runs the deterministic, non-publishing miniature Blueprint test."

  alias HydraAgent.Simulations.{BlueprintPackage, BlueprintVersion, JsonSchema}

  def run(%BlueprintVersion{} = version) do
    run(%{
      manifest: version.manifest,
      instructions: version.instructions,
      schemas: version.schemas,
      examples: version.examples,
      readme: version.readme
    })
  end

  def run(components) when is_map(components) do
    with {:ok, package} <- BlueprintPackage.from_components(components) do
      outputs = mock_outputs()
      failures = validate_outputs(package.schemas, outputs)

      {:ok,
       %{
         status: if(failures == [], do: "passed", else: "failed"),
         published: false,
         package: %{
           id: package.manifest["id"],
           version: package.manifest["version"],
           content_hash: package.content_hash,
           structure: "valid"
         },
         context_pack: outputs.context,
         agents: outputs.agents,
         script: outputs.script,
         preview: preview_result(),
         report: outputs.report,
         cost: %{
           currency: "USD",
           estimated: "0.00",
           actual: "0.00",
           provider_calls: 0,
           note: "Deterministic mock test; no provider credentials used."
         },
         warnings: package.compatibility_warnings,
         failures: failures
       }}
    end
  end

  defp validate_outputs(schemas, outputs) do
    [
      {"context_pack", "schemas/context-pack.schema.json", outputs.context},
      {"population_model", "schemas/population-model.schema.json", outputs.agents},
      {"simulation_script", "schemas/simulation-script.schema.json", outputs.script},
      {"report", "schemas/report.schema.json", outputs.report}
    ]
    |> Enum.flat_map(fn {stage, path, value} ->
      case JsonSchema.validate(schemas[path], value) do
        :ok ->
          []

        {:error, errors} ->
          Enum.map(errors, fn error ->
            %{
              "stage" => stage,
              "path" => error["path"],
              "message" => error["message"]
            }
          end)
      end
    end)
  end

  defp mock_outputs do
    %{
      context: %{
        "hydra_context_pack" => 1,
        "question" => "How might participants respond to a bounded change?",
        "facts" => [
          %{
            "id" => "fact-1",
            "statement" => "The miniature test uses explicit mock context.",
            "grounding_class" => "assumption"
          }
        ],
        "assumptions" => ["No external sources or private data are used."]
      },
      agents: %{
        "hydra_population_model" => 1,
        "population_size" => 3,
        "archetypes" => [
          %{
            "id" => "participant",
            "count" => 3,
            "goals" => ["adapt while preserving resources"],
            "initial_state" => %{"stance" => "undecided"}
          }
        ]
      },
      script: %{
        "hydra_simulation_script" => 1,
        "metadata" => %{"id" => "miniature_test", "title" => "Miniature test", "locale" => "en"},
        "clock" => %{"kind" => "rounds", "count" => 2, "label" => "round"},
        "world" => %{"state" => %{"change_introduced" => true}},
        "agent_types" => [
          %{
            "id" => "participant",
            "policy" => "participant_policy",
            "perception" => "participant_default"
          }
        ],
        "relationships" => [],
        "resources" => [],
        "events" => [],
        "actions" => [%{"id" => "adapt", "actors" => ["participant"]}],
        "perception" => %{"participant_default" => %{}},
        "policies" => [
          %{"id" => "participant_policy", "kind" => "fixed", "action" => "adapt"}
        ],
        "transitions" => [],
        "observations" => %{
          "metrics" => [%{"id" => "adapted_count", "kind" => "action_count", "action" => "adapt"}]
        },
        "stopping_conditions" => [%{"kind" => "final_round"}]
      },
      report: %{
        "title" => "Miniature simulation report",
        "summary" => "The mock participants followed the deterministic preview rules.",
        "sections" =>
          Enum.map(1..9, fn _ ->
            %{
              "heading" => "Recorded result",
              "body" => "Adaptation changed during the miniature preview.",
              "references" => ["snapshot-round-1", "snapshot-round-2"]
            }
          end),
        "limitations" => ["The miniature population is synthetic."],
        "recommended_next_steps" => ["Compare the direction with observed evidence."]
      }
    }
  end

  defp preview_result do
    %{
      seed: 1,
      population_size: 3,
      rounds: 2,
      snapshots: [
        %{"id" => "snapshot-round-1", "round" => 1, "adapted" => 1, "undecided" => 2},
        %{"id" => "snapshot-round-2", "round" => 2, "adapted" => 2, "undecided" => 1}
      ],
      population_conserved: true,
      provider_calls: 0
    }
  end
end
