defmodule HydraAgent.SimLab.BehaviorCompilerTest do
  use ExUnit.Case, async: true

  alias HydraAgent.SimLab.BehaviorCompiler

  test "compiles a complete editable and executable directional model" do
    compiled = BehaviorCompiler.compile(learning_study())
    personas = Enum.map(compiled.personas, & &1.persona)
    patterns = Enum.flat_map(compiled.personas, & &1.patterns)

    assert compiled.protocol_version == "sim-lab-behavior-compiler/v1"
    assert compiled.persona_count == 5
    assert compiled.pattern_count == 20
    assert length(personas) == 5
    assert length(patterns) == 20
    assert Enum.sum_by(personas, & &1.distribution_weight) == 1.0

    assert Enum.all?(personas, fn persona ->
             persona.goals != [] and persona.frictions != [] and persona.triggers != [] and
               persona.trust_factors != [] and is_binary(persona.decision_style) and
               persona.likely_actions != [] and persona.assumption_refs != [] and
               persona.behavioral_parameters["compiler_protocol"] == compiled.protocol_version and
               persona.version == 1 and persona.status == "active"
           end)

    assert Enum.all?(patterns, fn pattern ->
             is_binary(pattern.condition) and is_binary(pattern.interpretation) and
               is_binary(pattern.motivation) and
               pattern.likely_action in ~w(adopt resist ignore share) and
               pattern.base_probability >= 0.0 and pattern.base_probability <= 1.0 and
               pattern.assumption_refs != [] and pattern.state_updates != %{} and
               get_in(pattern, [:executable_rule, "protocol_version"]) ==
                 compiled.protocol_version and
               get_in(pattern, [:executable_rule, "population_share"]) == 0.25 and
               is_binary(get_in(pattern, [:executable_rule, "observable_action"])) and
               factor_weight(pattern.blockers) < 0 and factor_weight(pattern.amplifiers) > 0
           end)
  end

  test "no-data studies remain assumption-only and low confidence" do
    synthetic_hypothesis = %{
      id: 99,
      grounding_level: "assumption",
      confidence_score: 0.5,
      claim: "A synthetic hypothesis that has not been sourced."
    }

    compiled =
      BehaviorCompiler.compile(
        learning_study(),
        %{version: 1, confidence: 0.25},
        [synthetic_hypothesis]
      )

    personas = Enum.map(compiled.personas, & &1.persona)
    patterns = Enum.flat_map(compiled.personas, & &1.patterns)

    assert compiled.grounded_evidence_count == 0

    assert Enum.all?(personas, fn persona ->
             persona.evidence_refs == [] and persona.grounding_mix == %{"assumption" => 1.0} and
               persona.confidence <= 0.34 and
               String.starts_with?(persona.editable_notes, "Assumption-only")
           end)

    assert Enum.all?(patterns, fn pattern ->
             pattern.evidence_refs == [] and pattern.grounding_level == "assumption" and
               pattern.confidence <= 0.34 and pattern.assumption_refs != []
           end)
  end

  test "evidence is distributed as provenance while assumptions and uncertainty remain visible" do
    context_pack = %{
      version: 3,
      confidence: 0.56,
      generated_by_protocol_version: "sim-lab-local-context/v1",
      summary: %{"domain" => "workforce learning", "audience" => "new managers"}
    }

    compiled = BehaviorCompiler.compile(learning_study(), context_pack, evidence())
    personas = Enum.map(compiled.personas, & &1.persona)
    patterns = Enum.flat_map(compiled.personas, & &1.patterns)
    linked_refs = personas |> Enum.flat_map(& &1.evidence_refs) |> MapSet.new()

    assert linked_refs == MapSet.new(~w(101 102 103 104 105))

    assert Enum.all?(personas, fn persona ->
             persona.evidence_refs != [] and persona.assumption_refs != [] and
               persona.grounding_mix["assumption"] == 0.3 and persona.confidence < 0.63 and
               String.contains?(persona.editable_notes, "provenance, not proof of causality")
           end)

    assert Enum.all?(patterns, fn pattern ->
             pattern.evidence_refs != [] and pattern.assumption_refs != [] and
               pattern.grounding_level in ~w(direct_user_data external_research) and
               pattern.confidence < 0.63 and
               pattern.executable_rule["evidence_is_provenance_not_causality"] == true
           end)
  end

  test "unreviewed external candidates cannot ground generated behavior" do
    [candidate | _] = evidence()
    candidate = put_in(candidate, [:metadata, "review_status"], "unreviewed")

    compiled =
      BehaviorCompiler.compile(learning_study(), %{version: 1, confidence: 0.6}, [candidate])

    assert compiled.grounded_evidence_count == 0

    assert Enum.all?(compiled.personas, fn %{persona: persona, patterns: patterns} ->
             persona.evidence_refs == [] and persona.grounding_mix == %{"assumption" => 1.0} and
               Enum.all?(
                 patterns,
                 &(&1.evidence_refs == [] and &1.grounding_level == "assumption")
               )
           end)
  end

  test "semantic context changes segments and conditions while identical inputs stay deterministic" do
    first = BehaviorCompiler.compile(learning_study(), nil, evidence())
    repeated = BehaviorCompiler.compile(learning_study(), nil, evidence())

    retail =
      BehaviorCompiler.compile(%{
        question: "Will shoppers adopt a faster retail checkout?",
        domain: "retail checkout",
        target_audience: "shoppers",
        region: "France",
        timeframe: "30 days",
        desired_outcomes: %{"primary" => "Complete checkout with less effort."}
      })

    assert first == repeated
    refute first.context_fingerprint == retail.context_fingerprint

    refute hd(first.personas).persona.segment == hd(retail.personas).persona.segment

    refute hd(first.personas).patterns |> hd() |> Map.fetch!(:condition) ==
             hd(retail.personas).patterns |> hd() |> Map.fetch!(:condition)

    assert hd(retail.personas).persona.segment =~ "shoppers"
    assert hd(retail.personas).persona.goals == ["Complete checkout with less effort."]
  end

  defp factor_weight([factor | _]), do: factor["weight"]

  defp learning_study do
    %{
      question:
        "How will new managers react if learning portfolios become visible in their profile?",
      domain: "workforce learning",
      target_audience: "new managers",
      region: "Germany",
      timeframe: "90 days",
      desired_outcomes: %{}
    }
  end

  defp evidence do
    [
      evidence(101, "external_research", "Adoption value and measurable benefit", [
        "market_context"
      ]),
      evidence(102, "direct_user_data", "Privacy controls and consent", ["regulatory"]),
      evidence(103, "direct_user_data", "Workflow effort and time", ["behavioral_research"]),
      evidence(104, "external_research", "Trusted peer recognition", [
        "competitor_analogue"
      ]),
      evidence(105, "external_research", "Evidence, criticism, and failure risk", [
        "negative_evidence"
      ])
    ]
  end

  defp evidence(id, grounding_level, claim, tags) do
    %{
      id: id,
      kind: "research_candidate",
      claim: claim,
      normalized_claim: String.downcase(claim),
      simulation_impact: "Directional input requiring review.",
      grounding_level: grounding_level,
      confidence_score: 0.55,
      tags: tags,
      metadata: %{"review_status" => "reviewed"}
    }
  end
end
