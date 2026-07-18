defmodule HydraAgent.SimLab.BehaviorCompiler do
  @moduledoc """
  Deterministically compiles a study brief, its active Context Pack, and stored
  evidence into an editable directional behavior model.

  The compiler deliberately does not turn evidence snippets into new claims.
  Evidence is used only for provenance, confidence, and deterministic routing;
  every generated mechanism and probability keeps an assumption reference.
  """

  alias HydraAgent.SimLab.Research.StudyParser

  @protocol_version "sim-lab-behavior-compiler/v1"
  @assumption_ref "compiler:directional-behavior-prior/v1"
  @patterns_per_persona 4

  @archetypes [
    %{
      key: :outcome,
      name: "Outcome-led evaluators",
      weight: 0.24,
      focus: ~w(value benefit outcome adoption market_context behavioral_research),
      decision_style: "Moves quickly once practical value is credible; otherwise waits.",
      likely_actions: ~w(adopt ignore share)
    },
    %{
      key: :control,
      name: "Control-conscious validators",
      weight: 0.20,
      focus: ~w(control privacy consent trust regulatory negative_evidence),
      decision_style: "Checks consent, reversibility, and control before participating.",
      likely_actions: ~w(resist ignore adopt)
    },
    %{
      key: :pragmatic,
      name: "Time-constrained pragmatists",
      weight: 0.21,
      focus: ~w(time effort workflow friction recent_news behavioral_research),
      decision_style: "Uses the lowest-effort workable path and postpones ambiguous choices.",
      likely_actions: ~w(ignore adopt resist)
    },
    %{
      key: :social,
      name: "Social-proof amplifiers",
      weight: 0.17,
      focus: ~w(peer social recognition share analogue competitor_analogue),
      decision_style:
        "Looks for trusted peer behavior before making the change visible to others.",
      likely_actions: ~w(share adopt ignore)
    },
    %{
      key: :skeptical,
      name: "Evidence-first skeptics",
      weight: 0.18,
      focus: ~w(evidence proof risk criticism failure negative_evidence market_context),
      decision_style: "Withholds commitment until the claim is independently credible.",
      likely_actions: ~w(ignore resist adopt)
    }
  ]

  @doc """
  Returns a persistable model without writing to the database.

  The same study, Context Pack, and evidence identifiers always produce the
  same result. The output contains five personas and four action patterns per
  persona, keeping the initial model legible while meeting full-population and
  executable-rule requirements.
  """
  def compile(study, context_pack \\ nil, evidence \\ []) when is_list(evidence) do
    context = compile_context(study, context_pack, evidence)
    grounded_evidence = Enum.filter(evidence, &grounded_evidence?/1)

    personas =
      @archetypes
      |> Enum.with_index()
      |> Enum.map(fn {archetype, index} ->
        selected_evidence = select_evidence(grounded_evidence, archetype.focus, index)
        persona = persona(archetype, context, context_pack, selected_evidence)

        patterns =
          archetype.key
          |> pattern_specs(context)
          |> Enum.with_index()
          |> Enum.map(fn {spec, pattern_index} ->
            pattern_evidence = evidence_for_pattern(selected_evidence, pattern_index)

            action_pattern(
              spec,
              archetype,
              context,
              context_pack,
              pattern_evidence,
              pattern_index
            )
          end)

        %{persona: persona, patterns: patterns}
      end)

    %{
      protocol_version: @protocol_version,
      context_fingerprint: context.fingerprint,
      persona_count: length(personas),
      pattern_count: length(personas) * @patterns_per_persona,
      grounded_evidence_count: length(grounded_evidence),
      personas: personas
    }
  end

  def protocol_version, do: @protocol_version

  defp compile_context(study, context_pack, evidence) do
    summary = value(context_pack, :summary) || %{}

    question =
      phrase(value(study, :question), "How might the audience respond to the change?", 500)

    parsed =
      StudyParser.parse(question, %{
        domain: value(study, :domain) || value(summary, :domain),
        region: value(study, :region),
        language: value(study, :language),
        target_audience: value(study, :target_audience) || value(summary, :audience)
      })

    domain = phrase(parsed.domain, "product adoption", 120)
    audience = phrase(parsed.target_audience, "target users", 120)
    change = phrase(parsed.change, "the proposed product change", 140)
    behavior = phrase(parsed.behavior, "decision behavior", 100)
    outcome = desired_outcome(value(study, :desired_outcomes))

    fingerprint_input = %{
      question: parsed.question,
      domain: domain,
      region: value(study, :region),
      timeframe: value(study, :timeframe),
      audience: audience,
      change: change,
      behavior: behavior,
      desired_outcome: outcome,
      context_version: value(context_pack, :version),
      context_protocol: value(context_pack, :generated_by_protocol_version),
      evidence_refs: evidence |> Enum.map(&evidence_ref/1) |> Enum.sort()
    }

    %{
      question: parsed.question,
      domain: domain,
      audience: audience,
      change: change,
      behavior: behavior,
      desired_outcome: outcome,
      region: phrase(value(study, :region), "the study region", 100),
      timeframe: phrase(value(study, :timeframe), "the study horizon", 100),
      fingerprint: fingerprint(fingerprint_input)
    }
  end

  defp persona(archetype, context, context_pack, evidence) do
    evidence_refs = Enum.map(evidence, &evidence_ref/1)

    %{
      name: archetype.name,
      segment: segment(archetype.key, context),
      distribution_weight: archetype.weight,
      goals: [goal(archetype.key, context)],
      frictions: [friction(archetype.key, context)],
      triggers: [trigger(archetype.key, context)],
      trust_factors: [trust_factor(archetype.key, context)],
      decision_style: archetype.decision_style,
      likely_actions: archetype.likely_actions,
      behavioral_parameters: %{
        "compiler_protocol" => @protocol_version,
        "context_fingerprint" => context.fingerprint,
        "context_pack_version" => value(context_pack, :version),
        "patterns_per_persona" => @patterns_per_persona,
        "model_kind" => "directional_prior"
      },
      evidence_refs: evidence_refs,
      assumption_refs: [@assumption_ref, "compiler:persona:#{archetype.key}/v1"],
      grounding_mix: grounding_mix(evidence),
      confidence: confidence(evidence, context_pack, 0.01),
      editable_notes: editable_notes(context_pack, evidence),
      version: 1,
      status: "active"
    }
  end

  defp action_pattern(spec, archetype, context, context_pack, evidence, pattern_index) do
    evidence_refs = Enum.map(evidence, &evidence_ref/1)
    assumption_ref = "compiler:pattern:#{archetype.key}:#{pattern_index + 1}/v1"

    %{
      name: spec.name,
      condition: spec.condition,
      interpretation: spec.interpretation,
      motivation: spec.motivation,
      likely_action: spec.action,
      base_probability: spec.probability,
      blockers: [factor(spec.blocker, spec.blocker_weight)],
      amplifiers: [factor(spec.amplifier, spec.amplifier_weight)],
      state_updates: spec.state_updates,
      grounding_level: dominant_grounding(evidence),
      evidence_refs: evidence_refs,
      assumption_refs: [@assumption_ref, assumption_ref],
      confidence: confidence(evidence, context_pack, spec.confidence_offset),
      executable_rule: %{
        "origin" => "deterministic_behavior_compiler",
        "protocol_version" => @protocol_version,
        "rule_version" => 1,
        "context_fingerprint" => context.fingerprint,
        "population_share" => 1 / @patterns_per_persona,
        "action_class" => spec.action,
        "observable_action" => spec.observable_action,
        "evaluation" => "condition_then_interpretation_then_action_unless_blocked",
        "test_coverage" => "compiled_contract/v1",
        "evidence_is_provenance_not_causality" => true
      },
      version: 1,
      status: "active"
    }
  end

  defp segment(:outcome, context),
    do:
      "#{context.audience} in #{context.domain} who need a visible practical outcome before changing behavior."

  defp segment(:control, context),
    do:
      "#{context.audience} in #{context.domain} who protect consent, reversibility, and personal control."

  defp segment(:pragmatic, context),
    do:
      "#{context.audience} in #{context.domain} who act only when #{context.change} fits the current workflow."

  defp segment(:social, context),
    do:
      "#{context.audience} in #{context.domain} who use trusted peer behavior to interpret #{context.change}."

  defp segment(:skeptical, context),
    do:
      "#{context.audience} in #{context.domain} who require credible proof before responding to #{context.change}."

  defp goal(:outcome, context),
    do: context.desired_outcome || "Get a clear, relevant benefit from #{context.change}."

  defp goal(:control, context), do: "Stay in control while evaluating #{context.change}."
  defp goal(:pragmatic, _context), do: "Complete necessary work with minimal extra effort."
  defp goal(:social, _context), do: "Make a socially safe decision that trusted peers understand."
  defp goal(:skeptical, _context), do: "Avoid regret by validating the promise before committing."

  defp friction(:outcome, context), do: "The payoff of #{context.change} is unclear or delayed."
  defp friction(:control, _context), do: "Defaults or permissions feel imposed or irreversible."
  defp friction(:pragmatic, _context), do: "The change adds attention, setup, or workflow cost."
  defp friction(:social, _context), do: "Peer norms and reputational consequences are unclear."
  defp friction(:skeptical, _context), do: "Claims are broad, weakly sourced, or hard to verify."

  defp trigger(:outcome, context), do: "A concrete benefit of #{context.change} becomes visible."
  defp trigger(:control, _context), do: "Consent, settings, or reversibility become salient."
  defp trigger(:pragmatic, _context), do: "A task or trusted prompt makes a decision unavoidable."
  defp trigger(:social, _context), do: "A trusted peer demonstrates an observable outcome."
  defp trigger(:skeptical, _context), do: "Relevant evidence can be checked independently."

  defp trust_factor(:outcome, context),
    do: "A reversible trial with a measurable outcome for #{context.audience}."

  defp trust_factor(:control, _context),
    do: "Explicit choice, clear settings, and a reliable undo path."

  defp trust_factor(:pragmatic, _context),
    do: "Low setup cost and a prompt inside the existing workflow."

  defp trust_factor(:social, _context), do: "Trusted peer use without coercive public comparison."

  defp trust_factor(:skeptical, _context),
    do: "Specific, relevant, independently verifiable evidence."

  defp pattern_specs(:outcome, context) do
    [
      spec(
        "Practical value becomes legible",
        "The scenario shows a concrete benefit of #{context.change} to #{context.audience}.",
        "The change can produce an outcome worth the switching effort.",
        "Make progress toward a relevant result.",
        "adopt",
        0.64,
        "The result is too distant or cannot be measured.",
        -0.20,
        "A reversible trial shows an immediate result.",
        0.18,
        %{"intent" => 0.16, "feature_awareness" => 0.12},
        "starts a reversible trial of the proposed change",
        0.02
      ),
      spec(
        "Value remains abstract",
        "#{context.audience} see #{context.change} described without a concrete outcome.",
        "The request competes with work that has a clearer payoff.",
        "Protect time for higher-confidence work.",
        "ignore",
        0.58,
        "The change requires attention before value is demonstrated.",
        -0.16,
        "A relevant before-and-after example makes the outcome legible.",
        0.14,
        %{"intent" => -0.10, "attention" => -0.08},
        "takes no action during the current scenario step",
        -0.01
      ),
      spec(
        "Demonstrated outcome becomes a peer signal",
        "A result from #{context.change} is visible and safe to discuss in #{context.domain}.",
        "Sharing the result may help peers evaluate the same decision.",
        "Make useful progress legible to others.",
        "share",
        0.42,
        "The result is private, ambiguous, or hard to reproduce.",
        -0.18,
        "The outcome is specific and easy for peers to verify.",
        0.16,
        %{"advocacy" => 0.14, "peer_visibility" => 0.12},
        "shares a verified outcome with a peer",
        -0.02
      ),
      spec(
        "Switching cost outweighs visible value",
        "Using #{context.change} requires a costly or irreversible commitment.",
        "The expected benefit does not justify the downside of switching.",
        "Avoid a poor value tradeoff.",
        "resist",
        0.36,
        "The commitment is difficult to reverse.",
        -0.22,
        "A staged opt-in reduces the initial commitment.",
        0.17,
        %{"intent" => -0.12, "resistance" => 0.13},
        "declines or disables the proposed change",
        -0.03
      )
    ]
  end

  defp pattern_specs(:control, context) do
    [
      spec(
        "Control is unavailable at the decision point",
        "The scenario introduces #{context.change} without an explicit choice or undo path.",
        "The change may remove control before its consequences are understood.",
        "Preserve consent and reversibility.",
        "resist",
        0.68,
        "The default takes effect before settings can be reviewed.",
        -0.24,
        "Clear opt-in controls are available before activation.",
        0.22,
        %{"trust" => -0.18, "resistance" => 0.20},
        "opens settings, opts out, or challenges the default",
        0.01
      ),
      spec(
        "Reversible control supports a trial",
        "#{context.audience} can inspect, reverse, and limit #{context.change} before committing.",
        "Trying the change no longer requires surrendering control.",
        "Evaluate the option without creating lock-in.",
        "adopt",
        0.48,
        "Settings are incomplete or difficult to find.",
        -0.19,
        "The undo path is explicit and has been demonstrated.",
        0.20,
        %{"trust" => 0.16, "intent" => 0.10},
        "enables a limited or reversible version of the change",
        0.02
      ),
      spec(
        "Responsibility for control is unclear",
        "Ownership of consent or settings for #{context.change} is ambiguous.",
        "Acting now may create an exposure that nobody clearly owns.",
        "Wait until responsibility and recourse are clear.",
        "ignore",
        0.56,
        "No accountable owner is visible.",
        -0.16,
        "A named owner explains the control boundary.",
        0.14,
        %{"trust" => -0.10, "attention" => -0.06},
        "defers the decision and takes no action",
        -0.01
      ),
      spec(
        "Safe control practice is shared",
        "A trusted peer demonstrates how to use #{context.change} without losing control.",
        "The control boundary is concrete enough to help others decide safely.",
        "Protect peers from avoidable exposure.",
        "share",
        0.34,
        "The demonstration omits edge cases or recovery steps.",
        -0.15,
        "The peer shows both activation and reversal.",
        0.17,
        %{"trust" => 0.10, "peer_visibility" => 0.10},
        "shares control instructions with a peer",
        -0.02
      )
    ]
  end

  defp pattern_specs(:pragmatic, context) do
    [
      spec(
        "A workflow prompt makes the next step clear",
        "A relevant task prompts #{context.audience} to use #{context.change} inside the current workflow.",
        "The change is the shortest credible route to finishing the task.",
        "Complete necessary work with minimal coordination.",
        "adopt",
        0.52,
        "The prompt sends the user into a separate setup flow.",
        -0.18,
        "The first useful action is available in context.",
        0.18,
        %{"attention" => 0.12, "intent" => 0.11},
        "uses the proposed change for the prompted task",
        0.01
      ),
      spec(
        "No immediate task requires a decision",
        "#{context.change} appears without a relevant task or deadline for #{context.audience}.",
        "Deferring costs less than evaluating an optional change now.",
        "Protect limited attention.",
        "ignore",
        0.72,
        "The explanation requires additional reading or setup.",
        -0.16,
        "A time-bounded task makes the benefit immediately relevant.",
        0.13,
        %{"attention" => -0.14, "intent" => -0.08},
        "takes no action until a relevant task appears",
        0.02
      ),
      spec(
        "Extra work creates active rejection",
        "The scenario adds repeated setup or duplicate work to #{context.change}.",
        "The operating cost is likely to recur after adoption.",
        "Prevent avoidable workflow overhead.",
        "resist",
        0.44,
        "The extra step is mandatory and recurring.",
        -0.20,
        "Automation removes the repeated work.",
        0.17,
        %{"resistance" => 0.14, "intent" => -0.12},
        "declines the workflow or returns to the previous path",
        -0.01
      ),
      spec(
        "A useful shortcut is worth passing on",
        "A repeatable shortcut for #{context.change} saves effort in #{context.domain}.",
        "Sharing the shortcut reduces future coordination cost.",
        "Help peers complete the same work faster.",
        "share",
        0.38,
        "The shortcut only works in a narrow edge case.",
        -0.15,
        "The time saving repeats across common tasks.",
        0.16,
        %{"advocacy" => 0.10, "peer_visibility" => 0.09},
        "shares a repeatable workflow shortcut",
        -0.02
      )
    ]
  end

  defp pattern_specs(:social, context) do
    [
      spec(
        "Trusted peer use becomes visible",
        "A trusted peer demonstrates a concrete use of #{context.change}.",
        "The peer signal lowers uncertainty about acceptable behavior.",
        "Help the group coordinate around a credible example.",
        "share",
        0.58,
        "The example looks promotional or unrepresentative.",
        -0.18,
        "The peer is relevant to #{context.audience} and shows a real outcome.",
        0.19,
        %{"advocacy" => 0.16, "peer_visibility" => 0.15},
        "shares or recommends the peer-demonstrated use",
        0.02
      ),
      spec(
        "Recognition makes participation worthwhile",
        "The scenario recognizes a meaningful outcome from #{context.change} without forcing publicity.",
        "Participation can create a useful and socially safe signal.",
        "Make credible contribution visible.",
        "adopt",
        0.55,
        "Recognition is generic, competitive, or difficult to control.",
        -0.20,
        "Recognition is specific and optional.",
        0.17,
        %{"intent" => 0.13, "peer_visibility" => 0.10},
        "participates and keeps the outcome visible to selected peers",
        0.01
      ),
      spec(
        "Peer norms remain ambiguous",
        "#{context.audience} cannot tell whether peers in #{context.domain} use #{context.change}.",
        "Acting first may carry an unknown reputational cost.",
        "Avoid a socially exposed decision.",
        "ignore",
        0.48,
        "Only aggregate popularity claims are available.",
        -0.15,
        "A trusted peer explains why the change was useful.",
        0.15,
        %{"attention" => -0.07, "trust" => -0.08},
        "waits for a trusted peer signal",
        -0.01
      ),
      spec(
        "Public comparison creates reputational risk",
        "The scenario frames #{context.change} as a visible comparison among peers.",
        "Participation may expose status or performance without adequate control.",
        "Avoid coercive comparison.",
        "resist",
        0.46,
        "Visibility is public by default.",
        -0.22,
        "Private participation and audience controls are available.",
        0.18,
        %{"resistance" => 0.15, "trust" => -0.13},
        "hides, disables, or objects to the comparison",
        -0.02
      )
    ]
  end

  defp pattern_specs(:skeptical, context) do
    [
      spec(
        "Relevant evidence supports a bounded trial",
        "Specific evidence relevant to #{context.audience} is available for #{context.change}.",
        "A limited test can check the claim without assuming it is universally true.",
        "Reduce uncertainty through a falsifiable trial.",
        "adopt",
        0.46,
        "The evidence does not match the study context.",
        -0.22,
        "The outcome and comparison are independently checkable.",
        0.21,
        %{"trust" => 0.14, "intent" => 0.10},
        "starts a bounded trial and checks the stated outcome",
        0.02
      ),
      spec(
        "Unsupported claims are set aside",
        "#{context.change} is presented through broad claims without inspectable support.",
        "There is not enough information to update the current decision.",
        "Avoid acting on weak evidence.",
        "ignore",
        0.66,
        "The claim relies on authority without a checkable method.",
        -0.18,
        "A source, method, and relevant comparison are provided.",
        0.17,
        %{"attention" => -0.09, "trust" => -0.12},
        "takes no action and records an evidence question",
        0.01
      ),
      spec(
        "Contradictory outcomes trigger rejection",
        "Observed results for #{context.change} conflict with the promised outcome.",
        "The downside of the discrepancy now outweighs the uncertain benefit.",
        "Avoid repeating a contradicted approach.",
        "resist",
        0.54,
        "The contradiction is dismissed without investigation.",
        -0.20,
        "The discrepancy is explained and tested transparently.",
        0.16,
        %{"resistance" => 0.17, "trust" => -0.16},
        "stops, disables, or challenges the contradicted change",
        0.0
      ),
      spec(
        "Verification method is useful to peers",
        "A repeatable way to evaluate #{context.change} is available in #{context.domain}.",
        "Sharing the method helps peers test the claim instead of copying a conclusion.",
        "Improve collective evidence quality.",
        "share",
        0.32,
        "The method depends on private or unavailable data.",
        -0.16,
        "The steps and limits can be reproduced.",
        0.17,
        %{"advocacy" => 0.09, "trust" => 0.08},
        "shares the verification method and its limits",
        -0.02
      )
    ]
  end

  defp spec(
         name,
         condition,
         interpretation,
         motivation,
         action,
         probability,
         blocker,
         blocker_weight,
         amplifier,
         amplifier_weight,
         state_updates,
         observable_action,
         confidence_offset
       ) do
    %{
      name: name,
      condition: condition,
      interpretation: interpretation,
      motivation: motivation,
      action: action,
      probability: probability,
      blocker: blocker,
      blocker_weight: blocker_weight,
      amplifier: amplifier,
      amplifier_weight: amplifier_weight,
      state_updates: state_updates,
      observable_action: observable_action,
      confidence_offset: confidence_offset
    }
  end

  defp factor(statement, weight) do
    %{
      "name" => statement,
      "statement" => statement,
      "weight" => weight
    }
  end

  defp select_evidence([], _focus, _index), do: []

  defp select_evidence(evidence, focus, index) do
    sorted = Enum.sort_by(evidence, &evidence_ref/1)

    relevant =
      sorted
      |> Enum.map(&{&1, relevance_matches(&1, focus)})
      |> Enum.filter(fn {_item, matches} -> matches > 0 end)
      |> Enum.sort_by(fn {item, matches} ->
        {-matches, -evidence_confidence(item), evidence_ref(item)}
      end)
      |> Enum.map(&elem(&1, 0))

    relevant_refs = MapSet.new(relevant, &evidence_ref/1)

    fallback =
      sorted
      |> rotate(index)
      |> Enum.reject(&MapSet.member?(relevant_refs, evidence_ref(&1)))

    (relevant ++ fallback)
    |> Enum.uniq_by(&evidence_ref/1)
    |> Enum.take(min(2, length(evidence)))
  end

  defp evidence_for_pattern([], _index), do: []

  defp evidence_for_pattern(evidence, index) do
    [Enum.at(evidence, rem(index, length(evidence)))]
  end

  defp relevance_matches(item, focus) do
    haystack =
      [
        value(item, :kind),
        value(item, :claim),
        value(item, :normalized_claim),
        value(item, :simulation_impact),
        value(item, :tags)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()

    Enum.count(focus, &String.contains?(haystack, &1))
  end

  defp rotate([], _index), do: []

  defp rotate(items, index) do
    offset = rem(index, length(items))
    {head, tail} = Enum.split(items, offset)
    tail ++ head
  end

  defp grounding_mix([]), do: %{"assumption" => 1.0}

  defp grounding_mix(evidence) do
    counts = Enum.frequencies_by(evidence, &(value(&1, :grounding_level) || "assumption"))
    total = length(evidence)

    evidence_mix =
      counts
      |> Enum.sort_by(&elem(&1, 0))
      |> Map.new(fn {level, count} ->
        {level, Float.round(count / total * 0.7, 4)}
      end)

    Map.put(evidence_mix, "assumption", 0.3)
  end

  defp dominant_grounding([]), do: "assumption"

  defp dominant_grounding(evidence) do
    evidence
    |> Enum.map(&(value(&1, :grounding_level) || "assumption"))
    |> Enum.max_by(&grounding_priority/1)
  end

  defp grounding_priority("direct_user_data"), do: 5
  defp grounding_priority("external_research"), do: 4
  defp grounding_priority("analogue_evidence"), do: 3
  defp grounding_priority("domain_prior"), do: 2
  defp grounding_priority("assumption"), do: 1
  defp grounding_priority(_level), do: 0

  defp confidence([], _context_pack, offset),
    do: Float.round(min(0.34, max(0.22, 0.29 + offset)), 2)

  defp confidence(evidence, context_pack, offset) do
    evidence_average = Enum.sum_by(evidence, &evidence_confidence/1) / length(evidence)
    context_confidence = numeric(value(context_pack, :confidence), evidence_average)

    (0.32 + evidence_average * 0.20 + context_confidence * 0.12 + offset)
    |> min(0.62)
    |> max(0.30)
    |> Float.round(2)
  end

  defp evidence_confidence(item), do: numeric(value(item, :confidence_score), 0.35)

  defp grounded_evidence?(item) do
    metadata = value(item, :metadata) || %{}

    value(metadata, :review_status) == "reviewed" and
      value(item, :grounding_level) in ~w(direct_user_data external_research analogue_evidence domain_prior)
  end

  defp editable_notes(_context_pack, []) do
    "Assumption-only directional prior. Add and review evidence before treating this segment as decision support."
  end

  defp editable_notes(context_pack, _evidence) do
    version = value(context_pack, :version) || "unversioned"

    "Compiled from the study brief and Context Pack v#{version}. Evidence links are provenance, not proof of causality; review every trait and probability."
  end

  defp desired_outcome(outcomes) when is_map(outcomes) do
    outcomes
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value(fn
      value when is_binary(value) -> phrase(value, nil, 180)
      _value -> nil
    end)
  end

  defp desired_outcome(_outcomes), do: nil

  defp evidence_ref(item) do
    item
    |> value(:id)
    |> case do
      nil ->
        fingerprint(%{
          claim: value(item, :claim),
          kind: value(item, :kind),
          grounding_level: value(item, :grounding_level)
        })

      id ->
        to_string(id)
    end
  end

  defp phrase(value, fallback, max_length) when is_binary(value) do
    case value |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> fallback
      present -> String.slice(present, 0, max_length)
    end
  end

  defp phrase(_value, fallback, _max_length), do: fallback

  defp numeric(value, _fallback) when is_number(value), do: value * 1.0
  defp numeric(_value, fallback), do: fallback

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp value(_value, _key), do: nil

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
