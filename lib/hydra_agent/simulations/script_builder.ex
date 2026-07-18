defmodule HydraAgent.Simulations.ScriptBuilder do
  @moduledoc "Builds a conservative provider-free Simulation Script from versioned inputs."

  alias HydraAgent.Simulations.{
    ContentHash,
    ContextPack,
    PopulationModel,
    ScriptValidator,
    SimulationScript,
    SimulationVersion
  }

  @max_repair_attempts 1

  def max_repair_attempts, do: @max_repair_attempts

  def build(
        %SimulationVersion{} = version,
        %ContextPack{} = context_pack,
        %PopulationModel{} = population_model,
        opts \\ []
      ) do
    population = PopulationModel.contract(population_model)
    type_ids = Enum.map(population_model.agent_types, & &1["id"])
    actions = action_ids(population_model)
    resources = resource_ids(population_model)
    relationships = relationship_definitions(population_model, type_ids)
    rounds = Keyword.get(opts, :rounds, round_count(version))

    script = %{
      "hydra_simulation_script" => 1,
      "metadata" => %{
        "id" => script_id(version.title),
        "title" => version.title,
        "locale" => version.locale
      },
      "clock" => %{
        "kind" => "rounds",
        "count" => rounds,
        "label" => clock_label(version.locale, version.normalized_input["horizon"])
      },
      "world" => %{
        "state" => %{
          "change_introduced" => false,
          "information_clarity" => normalized_confidence(context_pack.confidence),
          "current_round" => 0
        }
      },
      "agent_types" =>
        Enum.map(type_ids, fn type_id ->
          %{
            "id" => type_id,
            "policy" => "#{type_id}_response_policy",
            "perception" => "#{type_id}_default"
          }
        end),
      "relationships" => relationships,
      "resources" => Enum.map(resources, &resource_definition/1),
      "events" => [opening_event(type_ids)],
      "actions" => Enum.map(actions, &action_definition(&1, population_model.agent_types)),
      "perception" => perception(type_ids, relationships),
      "policies" => Enum.map(type_ids, &policy(&1, actions, population_model.agent_types)),
      "transitions" => [],
      "observations" => observations(actions, resources),
      "stopping_conditions" => [
        %{"kind" => "final_round"},
        %{"kind" => "no_state_changes", "rounds" => min(3, rounds)}
      ]
    }

    with {:ok, validation_report} <-
           ScriptValidator.validate(script, population, model_budget?: model_budget?(version)) do
      contract = %{
        "schema_version" => 1,
        "compiler_version" => SimulationScript.compiler_version(),
        "script" => script,
        "validation_report" => validation_report,
        "generation_metadata" => %{
          "route" => "deterministic_fallback",
          "model_calls" => 0,
          "repair_attempts" => 0,
          "source_context_hash" => context_pack.content_hash,
          "source_context_version" => context_pack.version,
          "source_population_hash" => population_model.content_hash,
          "source_population_version" => population_model.version,
          "protocol_version" => "hydra-script/v1"
        },
        "status" => "ready"
      }

      {:ok, Map.put(contract, "content_hash", ContentHash.digest(contract))}
    end
  end

  @doc "Validates one generated repair and never invokes the repair function more than once."
  def validate_with_repair(script, population, repair_fun, opts \\ [])
      when is_map(script) and is_function(repair_fun, 2) do
    case ScriptValidator.validate(script, population, opts) do
      {:ok, report} ->
        {:ok, %{script: script, validation_report: report, repair_attempts: 0}}

      {:error, errors} ->
        case repair_fun.(script, errors) do
          repaired when is_map(repaired) ->
            case ScriptValidator.validate(repaired, population, opts) do
              {:ok, report} ->
                {:ok, %{script: repaired, validation_report: report, repair_attempts: 1}}

              {:error, repair_errors} ->
                {:error, %{errors: repair_errors, repair_attempts: @max_repair_attempts}}
            end

          _invalid_repair ->
            {:error,
             %{
               errors: [
                 %{
                   "path" => "$",
                   "code" => "invalid_repair",
                   "message" => "the bounded repair did not return a script object"
                 }
               ],
               repair_attempts: @max_repair_attempts
             }}
        end
    end
  end

  defp action_ids(population_model) do
    population_model.agent_types
    |> Enum.flat_map(&(&1["actions"] || []))
    |> Enum.uniq()
    |> Enum.take(24)
    |> case do
      [] -> ["observe"]
      actions -> actions
    end
  end

  defp resource_ids(population_model) do
    population_model.agent_types
    |> Enum.flat_map(&(&1["resources"] || []))
    |> Enum.uniq()
    |> Enum.take(24)
  end

  defp relationship_definitions(population_model, type_ids) do
    population_model.relationship_rules
    |> Enum.map(fn rule ->
      id = rule["relationship_type"] || "connected"
      settings = rule["settings"] || %{}

      %{
        "id" => id,
        "source_types" => source_types(rule["kind"], settings, type_ids),
        "target_types" => target_types(rule["kind"], settings, type_ids),
        "directed" => rule["directed"] == true
      }
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(32)
  end

  defp source_types("bipartite", settings, type_ids),
    do: member_or_all(settings["left_type"], type_ids)

  defp source_types(_kind, _settings, type_ids), do: type_ids

  defp target_types("bipartite", settings, type_ids),
    do: member_or_all(settings["right_type"], type_ids)

  defp target_types(_kind, _settings, type_ids), do: type_ids

  defp member_or_all(value, type_ids), do: if(value in type_ids, do: [value], else: type_ids)

  defp resource_definition(id) do
    %{
      "id" => id,
      "label" => humanize_resource(id),
      "unit" => resource_unit(id),
      "precision" => 4,
      "constraints" => %{"min" => 0.0, "max" => 1.0},
      "allow_negative" => false,
      "mint_allowed" => true,
      "burn_allowed" => true,
      "visibility" => "participants",
      "aggregation" => "sum"
    }
  end

  defp opening_event(type_ids) do
    %{
      "id" => "simulation_begins",
      "at_round" => 1,
      "phase" => "before_actions",
      "audience" => if(type_ids == [], do: %{"all" => true}, else: %{"all" => true}),
      "effects" => [
        %{"op" => "set_world", "path" => "change_introduced", "value" => true},
        %{"op" => "set_world", "path" => "current_round", "value" => 1}
      ]
    }
  end

  defp action_definition(action_id, agent_types) do
    actors =
      agent_types
      |> Enum.filter(&(action_id in (&1["actions"] || [])))
      |> Enum.map(& &1["id"])
      |> case do
        [] -> Enum.map(agent_types, & &1["id"])
        values -> values
      end

    %{
      "id" => action_id,
      "actors" => actors,
      "preconditions" => %{
        "fact" => "world.change_introduced",
        "op" => "eq",
        "value" => true
      },
      "costs" => [],
      "effects" => [
        %{"op" => "set_agent", "path" => "state.last_action", "value" => action_id}
      ],
      "emits" => [
        %{"type" => "action_selected", "payload" => %{"action" => action_id}}
      ]
    }
  end

  defp perception(type_ids, relationships) do
    relationship_types = Enum.map(relationships, & &1["id"])

    Map.new(type_ids, fn type_id ->
      {"#{type_id}_default",
       %{
         "world" => ["change_introduced", "information_clarity", "current_round"],
         "self" => ["attributes", "state", "resources", "goals", "constraints"],
         "relationships" => %{"types" => relationship_types, "limit" => 20},
         "recent_events" => %{
           "types" => ["simulation_begins", "action_selected"],
           "rounds" => 2,
           "limit" => 50
         }
       }}
    end)
  end

  defp policy(type_id, all_actions, agent_types) do
    type_actions =
      agent_types
      |> Enum.find(&(&1["id"] == type_id))
      |> case do
        nil -> all_actions
        type -> Enum.filter(all_actions, &(&1 in (type["actions"] || [])))
      end
      |> case do
        [] -> all_actions
        values -> values
      end

    candidates =
      type_actions
      |> Enum.with_index()
      |> Map.new(fn {action_id, index} ->
        {action_id, Float.round(max(0.1, 1.0 - index * 0.08), 2)}
      end)

    %{
      "id" => "#{type_id}_response_policy",
      "kind" => "weighted",
      "candidates" => candidates
    }
  end

  defp observations(actions, resources) do
    action_metrics =
      actions
      |> Enum.take(12)
      |> Enum.map(fn action_id ->
        %{"id" => "#{action_id}_count", "kind" => "action_count", "action" => action_id}
      end)

    resource_metrics =
      resources
      |> Enum.take(8)
      |> Enum.map(fn resource_id ->
        %{
          "id" => "#{resource_id}_total",
          "kind" => "resource_sum",
          "resource" => resource_id
        }
      end)

    %{
      "metrics" =>
        [
          %{
            "id" => "primary_action_rate",
            "kind" => "agent_fraction",
            "filter" => %{"state.last_action" => hd(actions)}
          }
        ] ++ action_metrics ++ resource_metrics,
      "traces" => %{
        "representatives_per_archetype" => 1,
        "high_influence" => 2,
        "outliers" => 2
      }
    }
  end

  defp round_count(version) do
    horizon = version.normalized_input["horizon"] || ""

    case Regex.run(~r/\b(\d{1,3})\b/u, horizon, capture: :all_but_first) do
      [count] -> count |> String.to_integer() |> max(1) |> min(50)
      _ -> 12
    end
  end

  defp clock_label("ru", horizon) do
    if is_binary(horizon) and String.contains?(String.downcase(horizon), "недел"),
      do: "неделя",
      else: "раунд"
  end

  defp clock_label(_locale, horizon) do
    if is_binary(horizon) and String.contains?(String.downcase(horizon), "week"),
      do: "week",
      else: "round"
  end

  defp resource_unit("time"), do: "hours"
  defp resource_unit("budget"), do: "units"
  defp resource_unit(_id), do: "points"

  defp humanize_resource(id),
    do:
      id
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)

  defp normalized_confidence(value) when is_number(value), do: Float.round(value, 4)
  defp normalized_confidence(_value), do: 0.0

  defp model_budget?(version), do: version.execution_mode in ~w(balanced deep)

  defp script_id(title) do
    title
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> String.slice(0, 56)
    |> case do
      "" -> "simulation"
      <<first::utf8, _rest::binary>> = value when first in ?a..?z -> value
      value -> "simulation_#{value}"
    end
  end
end
