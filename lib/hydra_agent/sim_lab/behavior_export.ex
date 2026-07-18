defmodule HydraAgent.SimLab.BehaviorExport do
  @moduledoc """
  Human-readable export of a study's current behavior model.

  This deliberately exports the durable personas and executable rules rather
  than a generated narrative, keeping assumptions and versions inspectable.
  """

  def markdown(study, personas, patterns) do
    personas_by_id = Map.new(personas, &{&1.id, &1})

    [
      "# Behavior model · #{study.title}",
      "",
      "Study question: #{study.question}",
      "",
      "This export contains the current editable behavior model. Grounding and assumptions are retained; it is not evidence of a real-world outcome.",
      "",
      "## Personas",
      "",
      Enum.map_join(personas, "\n\n", &persona_markdown/1),
      "",
      "## Executable action patterns",
      "",
      Enum.map_join(patterns, "\n\n", &pattern_markdown(&1, personas_by_id)),
      ""
    ]
    |> IO.iodata_to_binary()
  end

  defp persona_markdown(persona) do
    [
      "### #{persona.name} · v#{persona.version}",
      "",
      "- Segment: #{persona.segment}",
      "- Population share: #{percentage(persona.distribution_weight)}",
      "- Confidence: #{percentage(persona.confidence)}",
      "- Goals: #{list_or_unspecified(persona.goals)}",
      "- Frictions: #{list_or_unspecified(persona.frictions)}",
      "- Triggers: #{list_or_unspecified(persona.triggers)}",
      "- Trust factors: #{list_or_unspecified(persona.trust_factors)}",
      "- Decision style: #{persona.decision_style || "Unspecified"}",
      "- Likely actions: #{list_or_unspecified(persona.likely_actions)}",
      "- Grounding mix: #{grounding_mix(persona.grounding_mix)}",
      "- Assumption references: #{list_or_unspecified(persona.assumption_refs)}",
      "- Evidence references: #{list_or_unspecified(persona.evidence_refs)}"
    ]
    |> Enum.join("\n")
  end

  defp pattern_markdown(pattern, personas_by_id) do
    [
      "### #{pattern.name} · v#{pattern.version}",
      "",
      "- Segments: #{pattern_personas(pattern.persona_ids, personas_by_id)}",
      "- When: #{pattern.condition}",
      "- Interpreted as: #{pattern.interpretation}",
      "- Because: #{pattern.motivation}",
      "- Likely action: #{pattern.likely_action} (#{percentage(pattern.base_probability)})",
      "- Confidence: #{percentage(pattern.confidence)}",
      "- Grounding: #{pattern.grounding_level}",
      "- Blockers: #{factor_list(pattern.blockers)}",
      "- Amplifiers: #{factor_list(pattern.amplifiers)}",
      "- Assumption references: #{list_or_unspecified(pattern.assumption_refs)}",
      "- Evidence references: #{list_or_unspecified(pattern.evidence_refs)}"
    ]
    |> Enum.join("\n")
  end

  defp pattern_personas(ids, personas_by_id) do
    ids
    |> Enum.map(&Map.get(personas_by_id, &1))
    |> Enum.map(&if(&1, do: &1.name, else: "Archived or unavailable segment"))
    |> Enum.join(", ")
  end

  defp factor_list(factors) do
    factors
    |> Enum.map(fn factor -> factor["statement"] || factor[:statement] || inspect(factor) end)
    |> list_or_unspecified()
  end

  defp grounding_mix(mix) when map_size(mix) == 0, do: "Unspecified"

  defp grounding_mix(mix) do
    mix
    |> Enum.map_join(", ", fn {kind, value} -> "#{kind}: #{percentage(value)}" end)
  end

  defp list_or_unspecified([]), do: "Unspecified"
  defp list_or_unspecified(nil), do: "Unspecified"
  defp list_or_unspecified(values) when is_list(values), do: Enum.join(values, ", ")
  defp list_or_unspecified(value), do: to_string(value)

  defp percentage(value) when is_number(value), do: "#{round(value * 100)}%"
  defp percentage(_value), do: "Unspecified"
end
