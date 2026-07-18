defmodule HydraAgent.Simulations.PopulationBuilder do
  @moduledoc "Builds a conservative provider-free Population Model from one Context Pack."

  alias HydraAgent.Simulations.{
    ContentHash,
    ContextPack,
    PopulationCompiler,
    PopulationModel,
    PopulationValidator,
    SimulationVersion
  }

  @type_weight_bases [0.60, 0.25, 0.15, 0.10, 0.08, 0.06, 0.05, 0.04]

  def build(%SimulationVersion{} = version, %ContextPack{} = context_pack, opts \\ []) do
    locale = version.locale
    interpretation = context_pack.interpretation || %{}

    type_ids =
      interpretation
      |> Map.get("agent_types", ["participant"])
      |> Enum.map(&safe_id/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(8)
      |> case do
        [] -> ["participant"]
        values -> values
      end

    weights = normalized_weights(length(type_ids))
    grounding = grounding_refs(context_pack)

    resources =
      interpretation |> Map.get("candidate_resources", []) |> safe_ids(8, ["time", "information"])

    actions =
      interpretation
      |> Map.get("candidate_actions", [])
      |> safe_ids(12, ["adopt", "delay", "resist"])

    base_agent_types =
      type_ids
      |> Enum.zip(weights)
      |> Enum.map(fn {type_id, weight} ->
        agent_type(type_id, weight, resources, actions, grounding, locale)
      end)

    base_archetypes =
      Enum.flat_map(base_agent_types, fn type ->
        [
          archetype(type, "adaptive", 0.56, grounding, locale),
          archetype(type, "cautious", 0.44, Enum.reverse(grounding), locale)
        ]
      end)

    imported_agents = Keyword.get(opts, :imported_agents, [])
    imported_relationships = Keyword.get(opts, :imported_relationships, [])
    import_summary = Keyword.get(opts, :import_summary, %{})
    type_profiles = Keyword.get(opts, :type_profiles, %{})

    {agent_types, archetypes, imported_agents} =
      apply_import_profiles(
        base_agent_types,
        base_archetypes,
        imported_agents,
        type_profiles,
        resources,
        actions,
        grounding,
        locale
      )

    seed = Keyword.get(opts, :seed, seed(version, context_pack))

    contract = %{
      "schema_version" => 1,
      "compiler_version" => PopulationModel.compiler_version(),
      "seed" => seed,
      "population_size" => version.population_size,
      "agent_types" => agent_types,
      "archetypes" => archetypes,
      "conditional_distributions" => [influence_condition()],
      "relationship_rules" => [relationship_rule()],
      "representative_rules" => %{
        "per_archetype" => 1,
        "high_influence" => 2,
        "outliers" => 2
      },
      "imported_agents" => imported_agents,
      "imported_relationships" => imported_relationships,
      "import_summary" => import_summary,
      "compile_summary" => %{},
      "generation_metadata" => %{
        "route" => "deterministic_fallback",
        "model_calls" => 0,
        "intended_use" => "aggregate_simulation",
        "source_context_hash" => context_pack.content_hash,
        "source_context_version" => context_pack.version,
        "sensitive_attributes_inferred" => false,
        "protocol_version" => "hydra-population/v1"
      },
      "status" => if(import_summary["error_count"] in [nil, 0], do: "ready", else: "partial")
    }

    with :ok <- PopulationValidator.validate(contract, context_pack),
         {:ok, compiled} <- PopulationCompiler.compile(contract) do
      final = Map.put(contract, "compile_summary", compiled.summary)
      {:ok, Map.put(final, "content_hash", ContentHash.digest(final))}
    end
  end

  defp agent_type(type_id, weight, resources, actions, grounding, locale) do
    %{
      "id" => type_id,
      "label" => label(type_id, locale),
      "description" => description(type_id, locale),
      "weight" => weight,
      "attributes" => [
        numeric_attribute("openness"),
        numeric_attribute("risk_tolerance"),
        numeric_attribute("influence"),
        numeric_attribute("information_access"),
        %{
          "key" => "initial_stance",
          "type" => "categorical",
          "sensitive" => false
        }
      ],
      "resources" => resources,
      "actions" => actions,
      "grounding" => grounding
    }
  end

  defp numeric_attribute(key) do
    %{
      "key" => key,
      "type" => "number",
      "min" => 0.0,
      "max" => 1.0,
      "sensitive" => false
    }
  end

  defp archetype(type, variant, weight, grounding, locale) do
    adaptive? = variant == "adaptive"

    %{
      "id" => safe_id("#{variant}_#{type["id"]}"),
      "agent_type" => type["id"],
      "weight" => weight,
      "summary" => archetype_summary(type["label"], variant, locale),
      "distributions" => %{
        "openness" =>
          if(adaptive?,
            do: %{"kind" => "beta", "alpha" => 3.2, "beta" => 2.0, "min" => 0.0, "max" => 1.0},
            else: %{"kind" => "beta", "alpha" => 1.8, "beta" => 3.2, "min" => 0.0, "max" => 1.0}
          ),
        "risk_tolerance" =>
          if(adaptive?,
            do: %{"kind" => "normal", "mean" => 0.58, "sd" => 0.16, "min" => 0.0, "max" => 1.0},
            else: %{"kind" => "normal", "mean" => 0.32, "sd" => 0.14, "min" => 0.0, "max" => 1.0}
          ),
        "influence" => %{
          "kind" => "beta",
          "alpha" => 2.0,
          "beta" => 4.5,
          "min" => 0.0,
          "max" => 1.0
        },
        "information_access" => %{"kind" => "uniform", "min" => 0.2, "max" => 0.9},
        "initial_stance" => %{
          "kind" => "categorical",
          "values" =>
            if(adaptive?,
              do: %{"open" => 0.52, "undecided" => 0.38, "resistant" => 0.10},
              else: %{"open" => 0.12, "undecided" => 0.48, "resistant" => 0.40}
            )
        }
      },
      "goals" => goals(variant, locale),
      "constraints" => constraints(variant, locale),
      "initial_state" => %{"phase" => "uncommitted"},
      "initial_resources" =>
        Map.new(type["resources"], &{&1, if(adaptive?, do: 0.58, else: 0.42)}),
      "policy_id" => "#{type["id"]}_response_policy",
      "memory_seeds" => memory_seeds(variant, locale),
      "grounding" => grounding
    }
  end

  defp influence_condition do
    %{
      "when" => %{"attribute" => "influence", "operator" => "gte", "value" => 0.7},
      "set" => %{
        "information_access" => %{
          "kind" => "beta",
          "alpha" => 4.0,
          "beta" => 2.0,
          "min" => 0.0,
          "max" => 1.0
        }
      }
    }
  end

  defp apply_import_profiles(
         types,
         archetypes,
         imported_agents,
         profiles,
         default_resources,
         actions,
         grounding,
         locale
       ) do
    profiles
    |> Enum.sort_by(fn {type_id, _profile} -> type_id end)
    |> Enum.reduce({types, archetypes, imported_agents}, fn {type_id, profile},
                                                            {types, archetypes, agents} ->
      case Enum.find(types, &(&1["id"] == type_id)) do
        nil ->
          attributes =
            case profile["attributes"] || [] do
              [] -> [numeric_attribute("imported_signal")]
              values -> values
            end

          resources =
            case profile["resources"] || [] do
              [] -> default_resources
              values -> values
            end

          type = %{
            "id" => type_id,
            "label" => label(type_id, locale),
            "description" => imported_type_description(type_id, locale),
            "weight" => 0.0,
            "attributes" => attributes,
            "resources" => resources,
            "actions" => actions,
            "grounding" => grounding
          }

          imported_archetype = imported_archetype(type, grounding, locale)

          agents =
            Enum.map(agents, fn agent ->
              if agent["type"] == type_id and is_nil(agent["archetype"]),
                do: Map.put(agent, "archetype", imported_archetype["id"]),
                else: agent
            end)

          {types ++ [type], archetypes ++ [imported_archetype], agents}

        existing ->
          updated =
            existing
            |> Map.update!("attributes", fn values ->
              (values ++ (profile["attributes"] || []))
              |> Enum.uniq_by(& &1["key"])
            end)
            |> Map.update!("resources", fn values ->
              Enum.sort(Enum.uniq(values ++ (profile["resources"] || [])))
            end)

          types = Enum.map(types, &if(&1["id"] == type_id, do: updated, else: &1))
          {types, archetypes, agents}
      end
    end)
  end

  defp imported_archetype(type, grounding, locale) do
    %{
      "id" => safe_id("imported_#{type["id"]}"),
      "agent_type" => type["id"],
      "weight" => 1.0,
      "summary" =>
        if(locale == "ru",
          do: "Структурированные записи типа «#{type["label"]}», предоставленные пользователем.",
          else: "User-supplied structured records for the #{String.downcase(type["label"])} type."
        ),
      "distributions" => %{},
      "goals" =>
        if(locale == "ru",
          do: ["следовать предоставленному начальному состоянию"],
          else: ["follow the supplied initial state"]
        ),
      "constraints" => [],
      "initial_state" => %{"phase" => "imported"},
      "initial_resources" => %{},
      "policy_id" => "#{type["id"]}_response_policy",
      "memory_seeds" => [],
      "grounding" => grounding
    }
  end

  defp imported_type_description(type_id, "ru"),
    do: "Импортированная структурированная роль «#{label(type_id, "ru")}»."

  defp imported_type_description(type_id, _locale),
    do: "Imported structured #{String.downcase(label(type_id, "en"))} role."

  defp relationship_rule do
    %{
      "kind" => "small_world",
      "relationship_type" => "influences",
      "directed" => false,
      "settings" => %{"degree" => 4, "rewire_probability" => 0.08}
    }
  end

  defp grounding_refs(context_pack) do
    sourced =
      context_pack.claims
      |> Enum.filter(
        &(&1["grounding_class"] in ~w(user_data user_document external_source analogue))
      )

    priors = Enum.filter(context_pack.claims, &(&1["grounding_class"] == "model_prior"))

    (sourced ++ priors ++ context_pack.assumptions)
    |> Enum.map(& &1["id"])
    |> Enum.uniq()
    |> Enum.take(4)
  end

  defp normalized_weights(count) do
    bases =
      @type_weight_bases
      |> Enum.take(count)
      |> case do
        values when length(values) == count -> values
        values -> values ++ List.duplicate(0.03, count - length(values))
      end

    total = Enum.sum(bases)
    weights = Enum.map(bases, &Float.round(&1 / total, 9))
    difference = 1.0 - Enum.sum(weights)

    List.update_at(weights, -1, &Float.round(&1 + difference, 9))
  end

  defp seed(version, context_pack) do
    "#{version.content_hash}:#{context_pack.content_hash}:population"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 15)
    |> String.to_integer(16)
  end

  defp safe_ids(values, limit, fallback) do
    values
    |> List.wrap()
    |> Enum.map(&safe_id/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(limit)
    |> case do
      [] -> fallback
      ids -> ids
    end
  end

  defp safe_id(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      <<first::utf8, _rest::binary>> = id when first in ?a..?z -> String.slice(id, 0, 64)
      "" -> ""
      id -> String.slice("type_#{id}", 0, 64)
    end
  end

  defp label(id, "ru") do
    case id do
      "employee" -> "Сотрудник"
      "manager" -> "Руководитель"
      "informal_influencer" -> "Неформальный лидер"
      "participant" -> "Участник"
      "decision_maker" -> "Лицо, принимающее решение"
      "influencer" -> "Лидер мнений"
      "provider" -> "Поставщик"
      "peer_influencer" -> "Авторитетный участник"
      _ -> humanize(id)
    end
  end

  defp label(id, _locale), do: humanize(id)

  defp description(label_id, "ru"),
    do: "Роль «#{label(label_id, "ru")}» в моделируемой системе."

  defp description(label_id, _locale),
    do: "The #{String.downcase(label(label_id, "en"))} role in the modeled system."

  defp archetype_summary(type_label, "adaptive", "ru"),
    do: "#{type_label}: быстрее адаптируется, когда ценность понятна, а риск ограничен."

  defp archetype_summary(type_label, "cautious", "ru"),
    do: "#{type_label}: действует осторожно и ждёт подтверждений или социального сигнала."

  defp archetype_summary(type_label, "adaptive", _locale),
    do: "#{type_label} who adapts sooner when value is clear and downside is bounded."

  defp archetype_summary(type_label, "cautious", _locale),
    do: "#{type_label} who moves cautiously and waits for evidence or social proof."

  defp goals("adaptive", "ru"), do: ["получить практическую пользу", "сохранить свободу действий"]
  defp goals("cautious", "ru"), do: ["избежать ненужного риска", "сохранить устойчивость"]
  defp goals("adaptive", _locale), do: ["gain practical value", "preserve room to act"]
  defp goals("cautious", _locale), do: ["avoid unnecessary risk", "preserve stability"]

  defp constraints("adaptive", "ru"), do: ["ограниченное время", "неполная информация"]
  defp constraints("cautious", "ru"), do: ["низкая терпимость к неопределённости"]
  defp constraints("adaptive", _locale), do: ["limited time", "incomplete information"]
  defp constraints("cautious", _locale), do: ["low tolerance for uncertainty"]

  defp memory_seeds("adaptive", "ru"),
    do: ["Недавние полезные изменения повышают готовность пробовать."]

  defp memory_seeds("cautious", "ru"),
    do: ["Неясные изменения требуют дополнительного подтверждения."]

  defp memory_seeds("adaptive", _locale),
    do: ["Recent useful changes increase willingness to try."]

  defp memory_seeds("cautious", _locale), do: ["Ambiguous changes require more evidence."]

  defp humanize(id) do
    id
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
