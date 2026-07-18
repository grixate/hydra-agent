defmodule HydraAgent.SimLab.SchemasTest do
  use ExUnit.Case, async: true

  alias HydraAgent.SimLab.Schemas.{ActionPattern, EvidenceItem, Persona, SimulationRun, Study}

  test "study requires a question and uses the documented lifecycle" do
    changeset =
      Study.changeset(%Study{}, %{workspace_id: 1, title: "Launch", question: "Will it work?"})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == "draft"

    invalid =
      Study.changeset(%Study{}, %{
        workspace_id: 1,
        title: "Launch",
        question: "Will it work?",
        status: "uncertain"
      })

    assert "is invalid" in errors(invalid).status
  end

  test "evidence and behavior models reject fake precision" do
    evidence =
      EvidenceItem.changeset(%EvidenceItem{}, %{
        study_id: 1,
        claim: "People value control.",
        normalized_claim: "people value control",
        grounding_level: "assumption",
        simulation_impact: "May increase resistance.",
        confidence_score: 1.2
      })

    assert "must be less than or equal to %{number}" in errors(evidence).confidence_score

    persona =
      Persona.changeset(%Persona{}, %{
        study_id: 1,
        name: "Careful",
        segment: "Control-oriented",
        distribution_weight: 1.1
      })

    assert "must be less than or equal to %{number}" in errors(persona).distribution_weight
  end

  test "patterns and runs protect executable bounds" do
    pattern =
      ActionPattern.changeset(%ActionPattern{}, %{
        study_id: 1,
        name: "Control first",
        condition: "Visibility changes",
        interpretation: "This feels risky",
        motivation: "Maintain privacy",
        likely_action: "review_controls",
        base_probability: -0.1,
        grounding_level: "assumption"
      })

    assert "must be greater than or equal to %{number}" in errors(pattern).base_probability
    assert "is invalid" in errors(pattern).likely_action

    run =
      SimulationRun.changeset(%SimulationRun{}, %{
        study_id: 1,
        scenario_id: 1,
        context_pack_id: 1,
        mode: "large",
        agent_count: 0,
        rounds: 4,
        seed: 23
      })

    assert "must be greater than %{number}" in errors(run).agent_count
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _options} -> message end)
  end
end
