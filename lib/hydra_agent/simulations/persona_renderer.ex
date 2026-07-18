defmodule HydraAgent.Simulations.PersonaRenderer do
  @moduledoc "Creates a readable, non-authoritative projection for one representative agent."

  alias HydraAgent.Simulations.ContentHash

  def render(representative, locale) when is_map(representative) and locale in ~w(en ru) do
    projection =
      representative
      |> Map.take([
        "agent_id",
        "agent_type",
        "agent_type_label",
        "archetype_id",
        "archetype_summary",
        "attributes",
        "resources",
        "state",
        "goals",
        "constraints",
        "important_relationships",
        "grounding"
      ])
      |> Map.put("authoritative", false)
      |> Map.put("generated_lazily", true)

    prose = prose(projection, locale)
    payload = %{"projection" => projection, "prose" => prose, "generated_by" => "deterministic"}

    {:ok,
     %{
       projection: projection,
       prose: prose,
       generated_by: "deterministic",
       generated_lazily: true,
       content_hash: ContentHash.digest(payload)
     }}
  end

  def render(_representative, _locale), do: {:error, :invalid_representative}

  defp prose(projection, "ru") do
    type = projection["agent_type_label"]
    stance = trait_phrase(projection["attributes"], "ru")
    goal = projection |> Map.get("goals", []) |> List.first()
    constraint = projection |> Map.get("constraints", []) |> List.first()

    [
      "Репрезентативная роль: #{type}.",
      projection["archetype_summary"],
      stance,
      optional_sentence("Основная цель", goal),
      optional_sentence("Значимое ограничение", constraint),
      "Это читаемая проекция структурированного состояния, а не биография реального человека."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp prose(projection, _locale) do
    type = projection["agent_type_label"]
    stance = trait_phrase(projection["attributes"], "en")
    goal = projection |> Map.get("goals", []) |> List.first()
    constraint = projection |> Map.get("constraints", []) |> List.first()

    [
      "Representative role: #{type}.",
      projection["archetype_summary"],
      stance,
      optional_sentence("Primary goal", goal),
      optional_sentence("Meaningful constraint", constraint),
      "This is a readable projection of structured state, not a biography of a real person."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp trait_phrase(attributes, locale) do
    attributes
    |> Enum.filter(fn {_key, value} -> is_number(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(3)
    |> Enum.map(fn {key, value} -> "#{humanize(key, locale)}: #{level(value, locale)}" end)
    |> case do
      [] -> nil
      traits when locale == "ru" -> "Профиль: #{Enum.join(traits, ", ")}."
      traits -> "Profile: #{Enum.join(traits, ", ")}."
    end
  end

  defp level(value, "ru") when value < 0.34, do: "низкий уровень"
  defp level(value, "ru") when value < 0.67, do: "умеренный уровень"
  defp level(_value, "ru"), do: "высокий уровень"
  defp level(value, _locale) when value < 0.34, do: "lower"
  defp level(value, _locale) when value < 0.67, do: "moderate"
  defp level(_value, _locale), do: "higher"

  defp humanize(key, "ru") do
    case key do
      "openness" -> "готовность к изменениям"
      "risk_tolerance" -> "готовность к риску"
      "influence" -> "влияние"
      "information_access" -> "доступ к информации"
      _ -> String.replace(key, "_", " ")
    end
  end

  defp humanize(key, _locale), do: String.replace(key, "_", " ")

  defp optional_sentence(_label, nil), do: nil
  defp optional_sentence(label, value), do: "#{label}: #{value}."
end
