defmodule HydraAgent.Simulations.BuiltInBlueprints do
  @moduledoc "The two product-default Blueprint packages."

  alias HydraAgent.Simulations.BlueprintPackage

  @general_research """
  Research only the context needed to construct a useful agent-based simulation of the user's question.

  Identify the relevant world and institutions, likely agent types, important constraints and resources, known behavioral or operational mechanisms, recent local context when geography and time matter, plausible counter-evidence, and variables that may change the result.

  Keep user data, external sources, analogues, model priors, and assumptions separate. Do not infer sensitive traits unless the user supplied them and they are necessary. Prefer a compact, diverse evidence base over repetitive sources. Return a structured Context Pack matching the supplied schema.
  """

  @general_agents """
  Create a heterogeneous structured Population Model for the simulation.

  Generate only the agent types needed for the world; archetypes with meaningful behavioral or operational differences; bounded attribute distributions; goals and constraints; initial state and resources; typed relationship-generation rules; decision-policy references; and grounding links to evidence or explicit assumptions.

  Do not generate one prose biography per agent. Do not use demographic stereotypes as a shortcut. Do not optimize agents toward a preferred conclusion. Return a model Hydra can instantiate deterministically at different population sizes.
  """

  @general_simulation """
  Create a valid declarative Simulation Script for the supplied Population Model and question.

  Define a round-based clock, relevant world state, scheduled events, available actions, bounded perception, deterministic or hybrid policies, state transitions, resource costs and transfers, observations, and stopping conditions.

  Prefer the simplest script that can answer the question. Use model reasoning only for decisions that are ambiguous, novel, or high impact. Do not generate executable code or external side effects. Return a script matching the supplied schema.
  """

  @general_report """
  Interpret only the supplied Analysis Pack and permitted Context Pack.

  Explain the main result, how the world changed, important differences among agents and groups, resource and influence flows, pivotal modeled drivers, assumptions and uncertain areas, and useful next simulations or real-world validation.

  Every numeric, event, quotation, source, or agent claim must reference an ID supplied in the Analysis Pack or Context Pack. Use directional language. Do not describe synthetic population size as evidence strength or sample size.
  """

  @decision_cutoff """

  Use only information available on or before the information cutoff when building the simulation. Later information may be stored separately for calibration but must not influence the original Population Model, Script, Run, Analysis Pack, or initial Report. Flag uncertain publication dates and exclude them from strict replay by default.
  """

  @decision_simulation """

  Model the baseline and every declared alternative as comparable scenario variants. Preserve the same pre-outcome information boundary, population assumptions, seed policy, observation plan, and budget unless the user explicitly changes one. Record every difference between variants as structured provenance.
  """

  @decision_report """

  Include what the model would have recommended before the outcome, which modeled drivers mattered, what later happened when it is deliberately revealed, where the model aligned, where it failed, which missing mechanism or evidence may explain the error, and what should change in the next Blueprint Version. Never leak post-cutoff information into the original recommendation.
  """

  def all, do: [general_agent_simulation(), decision_replay()]

  def general_agent_simulation do
    package!(
      manifest(
        "general-agent-simulation",
        %{"en" => "General Agent Simulation", "ru" => "Универсальная агентная симуляция"},
        %{
          "en" => "Build a population, world, script, and report from a question.",
          "ru" => "Создаёт популяцию, мир, сценарий и отчёт на основе вопроса."
        },
        [
          %{"key" => "geography", "type" => "string", "required" => false},
          %{"key" => "horizon", "type" => "string", "required" => false},
          %{
            "key" => "population_size",
            "type" => "integer",
            "default" => 5000,
            "min" => 10,
            "max" => 100_000
          }
        ]
      ),
      %{
        "research" => @general_research,
        "agents" => @general_agents,
        "simulation" => @general_simulation,
        "report" => @general_report
      }
    )
  end

  def decision_replay do
    package!(
      manifest(
        "decision-replay",
        %{"en" => "Decision Replay", "ru" => "Реконструкция решения"},
        %{
          "en" => "Reconstruct a past decision without leaking later information.",
          "ru" => "Реконструирует прошлое решение без утечки более поздней информации."
        },
        [
          %{"key" => "decision_date", "type" => "string", "required" => true},
          %{"key" => "information_cutoff", "type" => "string", "required" => true},
          %{
            "key" => "observed_outcome_available",
            "type" => "boolean",
            "default" => false
          },
          %{"key" => "baseline_description", "type" => "string", "required" => true},
          %{
            "key" => "alternative_descriptions",
            "type" => "array",
            "required" => false
          }
        ]
      ),
      %{
        "research" => @general_research <> @decision_cutoff,
        "agents" => @general_agents,
        "simulation" => @general_simulation <> @decision_simulation,
        "report" => @general_report <> @decision_report
      }
    )
  end

  defp package!(manifest, instructions) do
    case BlueprintPackage.from_components(%{
           manifest: manifest,
           instructions: instructions,
           schemas: schemas(),
           examples: examples(),
           readme: readme(manifest)
         }) do
      {:ok, package} -> package
      {:error, reason} -> raise "invalid built-in Blueprint: #{inspect(reason)}"
    end
  end

  defp manifest(id, name, description, variables) do
    %{
      "hydra_blueprint" => 1,
      "id" => id,
      "name" => name,
      "version" => "1.0.0",
      "description" => description,
      "modules" => %{
        "research" => %{
          "instructions" => "instructions/research.md",
          "output_schema" => "schemas/context-pack.schema.json"
        },
        "agents" => %{
          "instructions" => "instructions/agents.md",
          "output_schema" => "schemas/population-model.schema.json"
        },
        "simulation" => %{
          "instructions" => "instructions/simulation.md",
          "output_schema" => "schemas/simulation-script.schema.json"
        },
        "report" => %{
          "instructions" => "instructions/report.md",
          "output_schema" => "schemas/report.schema.json"
        }
      },
      "variables" => variables,
      "capabilities" => %{
        "build" => ["structured_generation", "long_context"],
        "simulation" => ["optional_fast_reasoning"],
        "report" => ["structured_generation", "long_context"]
      },
      "defaults" => %{
        "execution_mode" => "quick",
        "research_budget" => "quick",
        "execution_budget" => "quick",
        "report_language" => "auto"
      },
      "compatibility" => %{
        "script_schema" => 1,
        "population_schema" => 1,
        "minimum_hydra_version" => "0.1.0"
      }
    }
  end

  defp schemas do
    %{
      "schemas/context-pack.schema.json" =>
        object_schema("context-pack", ~w(hydra_context_pack question facts assumptions), %{
          "hydra_context_pack" => %{"type" => "integer", "enum" => [1]},
          "question" => %{"type" => "string", "minLength" => 3},
          "facts" => %{
            "type" => "array",
            "items" =>
              object_schema(nil, ~w(id statement grounding_class), %{
                "id" => %{"type" => "string"},
                "statement" => %{"type" => "string"},
                "grounding_class" => %{
                  "type" => "string",
                  "enum" => [
                    "user_data",
                    "user_document",
                    "external_source",
                    "analogue",
                    "model_prior",
                    "assumption"
                  ]
                }
              })
          },
          "assumptions" => %{"type" => "array", "items" => %{"type" => "string"}}
        }),
      "schemas/population-model.schema.json" =>
        object_schema(
          "population-model",
          ~w(hydra_population_model population_size archetypes),
          %{
            "hydra_population_model" => %{"type" => "integer", "enum" => [1]},
            "population_size" => %{"type" => "integer", "minimum" => 1},
            "archetypes" => %{
              "type" => "array",
              "minItems" => 1,
              "items" =>
                object_schema(nil, ~w(id count goals initial_state), %{
                  "id" => %{"type" => "string"},
                  "count" => %{"type" => "integer", "minimum" => 0},
                  "goals" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "initial_state" => %{"type" => "object", "properties" => %{}}
                })
            }
          }
        ),
      "schemas/simulation-script.schema.json" =>
        object_schema(
          "simulation-script",
          ~w(hydra_simulation_script clock actions observations),
          %{
            "hydra_simulation_script" => %{"type" => "integer", "enum" => [1]},
            "clock" =>
              object_schema(nil, ~w(kind count label), %{
                "kind" => %{"type" => "string", "enum" => ["rounds"]},
                "count" => %{"type" => "integer", "minimum" => 1},
                "label" => %{"type" => "string"}
              }),
            "actions" => %{
              "type" => "array",
              "items" =>
                object_schema(nil, ~w(id actors), %{
                  "id" => %{"type" => "string"},
                  "actors" => %{"type" => "array", "items" => %{"type" => "string"}}
                })
            },
            "observations" => %{"type" => "object", "properties" => %{}}
          }
        ),
      "schemas/observation-plan.schema.json" =>
        object_schema("observation-plan", ~w(hydra_observation_plan metrics), %{
          "hydra_observation_plan" => %{"type" => "integer", "enum" => [1]},
          "metrics" => %{
            "type" => "array",
            "items" =>
              object_schema(nil, ~w(id kind), %{
                "id" => %{"type" => "string"},
                "kind" => %{"type" => "string"}
              })
          }
        }),
      "schemas/report.schema.json" =>
        object_schema("report", ~w(hydra_report summary claims), %{
          "hydra_report" => %{"type" => "integer", "enum" => [1]},
          "summary" => %{"type" => "string", "minLength" => 10},
          "claims" => %{
            "type" => "array",
            "items" =>
              object_schema(nil, ~w(id text references), %{
                "id" => %{"type" => "string"},
                "text" => %{"type" => "string"},
                "references" => %{
                  "type" => "array",
                  "minItems" => 1,
                  "items" => %{"type" => "string"}
                }
              })
          }
        })
    }
  end

  defp object_schema(id, required, properties) do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "required" => required,
      "properties" => properties,
      "additionalProperties" => true
    }
    |> maybe_put_id(id)
  end

  defp maybe_put_id(schema, nil), do: schema

  defp maybe_put_id(schema, id),
    do: Map.put(schema, "$id", "https://hydra.local/schemas/#{id}.schema.json")

  defp examples do
    %{
      "examples/sample-context.json" =>
        Jason.encode!(
          %{
            "hydra_context_pack" => 1,
            "question" => "How could a change affect this world?",
            "facts" => [],
            "assumptions" => ["No private data was supplied."]
          },
          pretty: true
        ),
      "examples/sample-population.json" =>
        Jason.encode!(
          %{
            "hydra_population_model" => 1,
            "population_size" => 3,
            "archetypes" => [
              %{"id" => "participant", "count" => 3, "goals" => ["adapt"], "initial_state" => %{}}
            ]
          },
          pretty: true
        ),
      "examples/sample-script.yaml" => "clock:\n  kind: rounds\n  count: 2\n  label: round\n",
      "examples/sample-report.json" =>
        Jason.encode!(
          %{
            "hydra_report" => 1,
            "summary" => "A miniature portable report.",
            "claims" => [%{"id" => "claim-1", "text" => "Example", "references" => ["fact-1"]}]
          },
          pretty: true
        )
    }
  end

  defp readme(manifest) do
    """
    # #{get_in(manifest, ["name", "en"])}

    This package is declarative and contains no executable code.

    1. Choose one file in `instructions/` and send it to an LLM as the task instruction.
    2. Supply the user question, the variables declared in `blueprint.yaml`, and outputs from the preceding stage.
    3. Require JSON matching the module's `output_schema` in `blueprint.yaml`.
    4. Validate the JSON against the corresponding file in `schemas/` before importing it into Hydra.

    Do not include private raw attachments when sharing this package. The Blueprint describes a method, not generated simulation data.
    """
  end
end
