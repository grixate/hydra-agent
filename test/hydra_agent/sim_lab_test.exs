defmodule HydraAgent.SimLabTest do
  use ExUnit.Case, async: true

  alias HydraAgent.SimLab.{
    Calibrations,
    Costing,
    Demo,
    Forecast,
    Notifications,
    RepresentativeTrace,
    SimulationInput,
    SimulationRunner,
    Simulations,
    Simulator
  }

  alias HydraAgent.SimLab.Research.{
    ConfiguredWebSearchProvider,
    PublicUrlFetcher,
    QueryAbstractor,
    Runner,
    StudyParser,
    WebResearchPlanner
  }

  alias HydraAgent.SimLab.Schemas.SimulationRun

  test "cost estimates report the deterministic engine's actual provider spend" do
    tiny = Costing.estimate(:tiny)
    large = Costing.estimate(:large)

    assert large.agents > tiny.agents
    assert large.expected_llm_calls == 0
    assert large.pattern_ratio == 1.0
    assert large.high_usd == 0.0
    assert large.low_usd == 0.0
    assert {:ok, _estimate} = Costing.authorize("large", 0)
    assert {:error, :budget_cap_exceeded} = Costing.authorize("large", -0.01)
  end

  test "calibration review recommends inspection for material drift without changing a model" do
    review =
      Calibrations.review([
        %{metric: "adopt", delta: 0.04},
        %{metric: "resist", delta: -0.22}
      ])

    assert review.tone == "review"
    assert review.label == "Model review recommended"
    assert review.body =~ "linked action patterns"
  end

  test "query abstraction removes private company and metric details" do
    query = "Sber HR certificate visibility for 48% of employees"

    assert QueryAbstractor.private?(query)

    assert QueryAbstractor.abstract(query) ==
             "organisation HR certificate visibility for market metric of employees"
  end

  test "simulation produces deterministic aggregate snapshots" do
    input = Demo.simulation_input()
    first = Simulator.run(input)
    second = Simulator.run(input)

    assert first == second
    assert length(first.snapshots) == 4
    assert Enum.all?(first.snapshots, &(length(&1.clusters) <= 10))
    assert first.decision_counts == %{pattern: 20_000, small_model: 0, large_model: 0}
    assert Enum.all?(first.snapshots, &(&1.cost.actual_usd == 0.0))
  end

  test "hundred-thousand-agent runs remain compact cohort aggregates" do
    result = Demo.simulation_input() |> Map.put(:agent_count, 100_000) |> Simulator.run()

    assert Enum.all?(result.snapshots, fn snapshot ->
             Enum.sum_by(snapshot.clusters, & &1.count) == 100_000
           end)

    assert Enum.all?(result.snapshots, &(length(&1.clusters) <= 10))
    assert result.decision_counts == %{pattern: 400_000, small_model: 0, large_model: 0}
  end

  test "weighted cohorts preserve every requested population across awkward sizes" do
    weight_sets = [
      [1.0],
      [0.3333, 0.3333, 0.3334],
      [0.07, 0.13, 0.20, 0.60],
      [0.01, 0.01, 0.98]
    ]

    for agent_count <- [1, 2, 3, 7, 50, 251, 1_000], weights <- weight_sets do
      personas =
        weights
        |> Enum.with_index()
        |> Enum.map(fn {weight, index} ->
          %{
            id: "p#{index}",
            name: "Persona #{index}",
            weight: weight,
            color: "#000",
            confidence: 0.8
          }
        end)

      patterns =
        Enum.map(personas, fn persona ->
          %{
            persona: persona.id,
            name: "Adopt #{persona.id}",
            action: "adopt",
            probability: 0.37,
            confidence: 0.8,
            share: 1.0,
            executable_rule: %{}
          }
        end)

      input = %{
        personas: personas,
        patterns: patterns,
        events: [%{day: 1, title: "Narrative", impact: "No declared mechanism"}],
        agent_count: agent_count,
        seed: 91
      }

      [snapshot] = Simulator.run(input).snapshots

      assert Enum.sum_by(snapshot.clusters, & &1.count) == agent_count
      assert Enum.all?(snapshot.clusters, &(&1.count > 0))
      assert Enum.all?(Map.values(snapshot.metrics), &(&1 >= 0.0 and &1 <= 1.0))
      assert_in_delta Enum.sum(Map.values(snapshot.metrics)), 1.0, 1.0e-12
    end
  end

  test "ignore probability represents the modeled chance of waiting" do
    input = %{
      personas: [%{id: "p", name: "Participants", weight: 1.0, color: "#000", confidence: 0.8}],
      patterns: [
        %{
          persona: "p",
          name: "Wait before acting",
          action: "ignore",
          probability: 0.2,
          confidence: 0.8,
          share: 1.0,
          executable_rule: %{}
        }
      ],
      events: [%{day: 1, title: "Announcement", impact: "Narrative only"}],
      agent_count: 1_000,
      seed: 42
    }

    [snapshot] = Simulator.run(input).snapshots

    assert snapshot.metrics["ignore"] == 0.2
    assert snapshot.metrics["adopt"] == 0.8
  end

  test "a missing action rule remains a waiting cohort" do
    scenario = %{
      id: 10,
      updated_at: ~U[2026-07-10 00:00:00Z],
      name: "Unmodelled scenario",
      events: [%{"day" => "1", "title" => "Announcement"}],
      metadata: %{}
    }

    personas = [%{id: 1, name: "Unmodelled", distribution_weight: 1.0, confidence: 0.7}]

    assert {:ok, compiled} = SimulationInput.build(personas, [], scenario, mode: "tiny")
    [snapshot] = Simulator.run(compiled.input).snapshots

    assert snapshot.metrics["ignore"] == 1.0
    assert snapshot.metrics["adopt"] == 0.0
  end

  test "an unknown action fails closed as waiting and preserves the metric total" do
    input = %{
      personas: [%{id: "p", name: "Participants", weight: 1.0, color: "#000", confidence: 0.8}],
      patterns: [
        %{
          persona: "p",
          name: "Unsupported behavior",
          action: "review_controls",
          probability: 0.8,
          confidence: 0.8,
          share: 1.0,
          executable_rule: %{}
        }
      ],
      events: [%{day: 1, title: "Announcement", impact: "Narrative only"}],
      agent_count: 100,
      seed: 42
    }

    [snapshot] = Simulator.run(input).snapshots

    assert snapshot.metrics["ignore"] == 1.0
    assert Enum.sum(Map.values(snapshot.metrics)) == 1.0
  end

  test "an explicit control-first counterfactual changes only resistance-labelled rules" do
    scenario = %{
      id: 1,
      updated_at: ~U[2026-07-10 00:00:00Z],
      name: "Opt-in visibility",
      events: [%{"day" => "1", "title" => "Opt-in framing"}],
      metadata: %{"simulation_modifier" => "control_first_opt_in"}
    }

    personas = [
      %{id: 1, name: "Privacy-sensitive", distribution_weight: 0.4, confidence: 0.6}
    ]

    patterns = [
      %{
        persona_ids: [1],
        name: "Default visibility feels unsafe",
        likely_action: "resist",
        base_probability: 0.7,
        confidence: 0.6
      }
    ]

    assert {:ok, compiled} = SimulationInput.build(personas, patterns, scenario, mode: "small")

    pattern = Enum.find(compiled.input.patterns, &(&1.persona == "1"))
    assert pattern.action == "resist"
    assert pattern.name =~ "control-first hypothesis"
    assert pattern.executable_rule["scenario_probability_delta"] == -0.2
    assert pattern.confidence == 0.55

    base_scenario = put_in(scenario.metadata, %{})

    assert {:ok, baseline} =
             SimulationInput.build(personas, patterns, base_scenario, mode: "small")

    modified_metrics =
      Simulator.run(compiled.input).snapshots |> List.last() |> Map.fetch!(:metrics)

    baseline_metrics =
      Simulator.run(baseline.input).snapshots |> List.last() |> Map.fetch!(:metrics)

    assert modified_metrics["resist"] < baseline_metrics["resist"]
    assert modified_metrics["ignore"] > baseline_metrics["ignore"]
  end

  test "a manager-recognition mechanism changes only hesitation-labelled rules" do
    scenario = %{
      id: 3,
      updated_at: ~U[2026-07-10 00:00:00Z],
      name: "Recognition scenario",
      events: [%{"day" => "1", "title" => "Manager recognition"}],
      metadata: %{"simulation_modifier" => "manager_recognition"}
    }

    personas = [%{id: 1, name: "Hesitant managers", distribution_weight: 1.0, confidence: 0.7}]

    patterns = [
      %{
        persona_ids: [1],
        name: "Wait for manager signal",
        likely_action: "ignore",
        base_probability: 0.6,
        confidence: 0.7
      }
    ]

    assert {:ok, compiled} = SimulationInput.build(personas, patterns, scenario, mode: "tiny")
    [pattern] = compiled.input.patterns
    assert pattern.action == "ignore"
    assert pattern.name =~ "manager-recognition hypothesis"
    assert pattern.executable_rule["scenario_probability_delta"] == -0.2
    assert pattern.confidence == 0.55

    base_scenario = put_in(scenario.metadata, %{})

    assert {:ok, baseline} =
             SimulationInput.build(personas, patterns, base_scenario, mode: "tiny")

    modified_metrics =
      Simulator.run(compiled.input).snapshots |> List.last() |> Map.fetch!(:metrics)

    baseline_metrics =
      Simulator.run(baseline.input).snapshots |> List.last() |> Map.fetch!(:metrics)

    assert modified_metrics["ignore"] < baseline_metrics["ignore"]
    assert modified_metrics["adopt"] > baseline_metrics["adopt"]
  end

  test "multiple action patterns split one persona into compact weighted cohorts" do
    scenario = %{
      id: 2,
      updated_at: ~U[2026-07-10 00:00:00Z],
      name: "Visibility test",
      events: [%{"day" => "1", "title" => "Announcement"}],
      metadata: %{}
    }

    personas = [%{id: 1, name: "Careful managers", distribution_weight: 1.0, confidence: 0.7}]

    patterns = [
      %{
        persona_ids: [1],
        name: "Seek privacy controls",
        likely_action: "resist",
        base_probability: 0.25,
        confidence: 0.7
      },
      %{
        persona_ids: [1],
        name: "Use a career signal",
        likely_action: "adopt",
        base_probability: 0.75,
        confidence: 0.7
      }
    ]

    assert {:ok, compiled} = SimulationInput.build(personas, patterns, scenario, mode: "tiny")
    assert Enum.map(compiled.input.patterns, & &1.share) == [0.5, 0.5]

    [snapshot] = Simulator.run(compiled.input).snapshots
    assert length(snapshot.clusters) == 4
    assert Enum.sum_by(snapshot.clusters, & &1.count) == compiled.input.agent_count

    assert snapshot.clusters
           |> Enum.map(& &1.dominant_pattern)
           |> MapSet.new() == MapSet.new(["Seek privacy controls", "Use a career signal"])
  end

  test "explicit event mechanisms change outcomes while narrative wording alone does not" do
    base = %{
      personas: [%{id: "p", name: "Participants", weight: 1.0, color: "#000", confidence: 0.8}],
      patterns: [
        %{
          persona: "p",
          name: "Try the change",
          action: "adopt",
          probability: 0.5,
          confidence: 0.8,
          share: 1.0,
          condition: "The launch becomes visible",
          blockers: [],
          amplifiers: [],
          executable_rule: %{}
        }
      ],
      events: [
        %{
          day: 1,
          title: "Launch becomes visible",
          impact: "An explicitly modeled mechanism",
          action_effects: %{"adopt" => 0.2}
        }
      ],
      agent_count: 1_000,
      seed: 42
    }

    negative =
      put_in(base.events, [Map.put(hd(base.events), :action_effects, %{"adopt" => -0.2})])

    narrative_only =
      put_in(base.events, [
        Map.merge(hd(base.events), %{impact: "opposite words", action_effects: %{}})
      ])

    narrative_reworded =
      put_in(base.events, [
        Map.merge(hd(base.events), %{
          title: "Completely unrelated language",
          impact: "No overlapping behavior terms",
          action_effects: %{}
        })
      ])

    positive_adoption =
      Simulator.run(base).snapshots |> List.last() |> then(& &1.metrics["adopt"])

    negative_adoption =
      Simulator.run(negative).snapshots |> List.last() |> then(& &1.metrics["adopt"])

    narrative_adoption =
      Simulator.run(narrative_only).snapshots |> List.last() |> then(& &1.metrics["adopt"])

    reworded_metrics =
      Simulator.run(narrative_reworded).snapshots |> List.last() |> Map.fetch!(:metrics)

    assert positive_adoption > narrative_adoption
    assert narrative_adoption > negative_adoption
    assert reworded_metrics == List.last(Simulator.run(narrative_only).snapshots).metrics
  end

  test "event days reject numeric prefixes instead of partially parsing them" do
    scenario = %{
      id: 11,
      updated_at: ~U[2026-07-10 00:00:00Z],
      name: "Strict event day",
      events: [%{"day" => "14 days", "title" => "Malformed day"}],
      metadata: %{}
    }

    personas = [%{id: 1, name: "Participants", distribution_weight: 1.0, confidence: 0.7}]

    assert {:ok, compiled} = SimulationInput.build(personas, [], scenario, mode: "tiny")
    assert [%{day: 1}] = compiled.input.events
  end

  test "configured external research fails closed without a provider endpoint" do
    original = Application.get_env(:hydra_agent, :sim_lab_web_search)
    Application.delete_env(:hydra_agent, :sim_lab_web_search)

    on_exit(fn ->
      if original, do: Application.put_env(:hydra_agent, :sim_lab_web_search, original)
    end)

    assert {:error, :not_configured} =
             ConfiguredWebSearchProvider.search(%{
               safe_query: "corporate learning visibility privacy",
               region: "Germany",
               language: "en"
             })
  end

  test "public URL ingestion rejects private hosts and accepts bounded public text" do
    assert {:error, :non_public_host} =
             PublicUrlFetcher.fetch("https://internal.example", %{
               resolver: fn _host -> {:ok, [{10, 0, 0, 5}]} end
             })

    assert {:ok, source} =
             PublicUrlFetcher.fetch("https://public.example/research", %{
               resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
               requester: fn options ->
                 assert options[:redirect] == false
                 assert options[:url] == "https://93.184.216.34/research"
                 assert options[:connect_options][:hostname] == "public.example"
                 assert {"host", "public.example"} in options[:headers]

                 {:ok,
                  %{
                    status: 200,
                    headers: [{"content-type", "text/html"}],
                    body:
                      "<html><title>Public study</title><body>Controls improve trust.</body></html>"
                  }}
               end
             })

    assert source.title == "Public study"
    assert source.text == "Public study Controls improve trust."

    assert {:error, :source_too_large} =
             PublicUrlFetcher.fetch("https://public.example/oversized", %{
               resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
               requester: fn options ->
                 response = %{
                   status: 200,
                   headers: [{"content-type", "text/plain"}],
                   body: ""
                 }

                 assert {:halt, {_request, bounded_response}} =
                          options[:into].(
                            {:data, String.duplicate("x", 1_000_001)},
                            {Req.new(), response}
                          )

                 {:ok, bounded_response}
               end
             })

    assert {:error, :invalid_public_https_url} =
             PublicUrlFetcher.fetch("https://127.0.0.1/research")
  end

  test "query abstraction reports common identifiers before external research" do
    audit =
      QueryAbstractor.analyze(
        "Ask Jane Doe at jane@example.com or +1 415 555 0123 about employee ID AB-1234 at https://internal.example/plan",
        private_entities: ["Jane Doe"]
      )

    refute audit.abstracted =~ "Jane Doe"
    refute audit.abstracted =~ "jane@example.com"
    refute audit.abstracted =~ "415 555"
    refute audit.abstracted =~ "AB-1234"
    refute audit.abstracted =~ "internal.example"
    assert audit.changed?
    assert Enum.any?(audit.findings, &(&1.kind == :known_private_entity))
    assert Enum.any?(audit.findings, &(&1.kind == :email))
    assert Enum.any?(audit.findings, &(&1.kind == :phone))
  end

  test "no-data research planning includes negative evidence and redacts private entities" do
    parsed =
      StudyParser.parse("How will Acme employees react if certificates become visible?",
        region: "Russia",
        language: "ru"
      )

    plan = WebResearchPlanner.plan(parsed, private_entities: ["Acme"])

    assert length(plan) == 7
    assert Enum.any?(plan, &(&1.lane == "negative_evidence"))
    assert Enum.all?(plan, &(not String.contains?(&1.safe_query, "Acme")))
    assert Enum.all?(plan, &(&1.region == "Russia" and &1.language == "ru"))
  end

  test "structured brief values can all be abstracted before outbound research" do
    parsed =
      StudyParser.parse("How will Project Nightjar customers react to the launch?",
        domain: "Project Nightjar",
        target_audience: "Founders Circle",
        region: "Unreleased Market"
      )

    private_values = [parsed.domain, parsed.target_audience, parsed.region]
    plan = WebResearchPlanner.plan(parsed, private_entities: private_values)

    assert Enum.all?(plan, fn lane ->
             Enum.all?(private_values, &(not String.contains?(lane.safe_query, &1)))
           end)

    assert Enum.all?(plan, &String.contains?(&1.safe_query, "private study detail"))
  end

  test "forecast remains directional and carries assumptions to validation" do
    report =
      Forecast.build(Simulator.run(Demo.simulation_input()), Demo.study(),
        assumptions: ["Manager recognition is assumed to be meaningful."]
      )

    assert report.executive_summary =~ "directionally led"
    assert report.markdown_body =~ "not a certainty"
    assert report.assumptions == ["Manager recognition is assumed to be meaningful."]
    assert Enum.any?(report.validation_recommendations, &String.contains?(&1, "assumption"))
    refute report.executive_summary =~ "visibility"
  end

  test "research runner only sends abstracted queries and preserves reviewable provenance" do
    parent = self()

    provider = fn lane ->
      send(parent, {:research_query, lane.safe_query})

      {:ok,
       [
         %{
           title: "Visibility research",
           url: "https://example.test/visibility",
           snippet: "Control settings can alter adoption.",
           reliability: "medium"
         }
       ]}
    end

    output =
      Runner.run(
        "How will Acme employees react to visible certificates?",
        %{region: "Russia"},
        provider,
        private_entities: ["Acme"]
      )

    assert length(output.sources) == 1
    assert length(output.evidence) == 1
    assert length(hd(output.evidence).metadata["lane_tags"]) == 7
    assert length(hd(output.evidence).metadata["provenance"]) == 7
    assert output.context_pack.status == "active"
    assert output.context_pack.confidence > 0
    assert Enum.all?(output.sources, &(&1.pii_status == "none" and &1.status == "parsed"))

    for _ <- 1..7 do
      assert_receive {:research_query, safe_query}
      refute safe_query =~ "Acme"
    end
  end

  test "simulation runner stores only aggregate replay payloads and cautious assumptions" do
    prepared =
      SimulationRunner.prepare(Demo.simulation_input(), Demo.study(),
        mode: "large",
        confidence: 0.62,
        assumptions: ["Managers are assumed to recognize certificates."]
      )

    assert prepared.run.mode == "large"
    assert prepared.run.status == "completed"
    assert prepared.run.decision_counts["pattern"] > prepared.run.decision_counts["large_model"]
    assert prepared.run.input_snapshot["seed"] == 713
    assert length(prepared.run.input_snapshot["personas"]) == 5
    assert String.length(prepared.run.input_fingerprint) == 64
    assert length(prepared.snapshots) == 4
    assert length(prepared.outcome_events) <= 40
    assert length(prepared.outcome_events) > 20
    assert Enum.all?(prepared.outcome_events, &(&1.metadata["llm_fallback_used"] == false))
    assert is_list(hd(prepared.snapshots).clusters["groups"])
    assert hd(prepared.snapshots).decision_counts["pattern"] == 5_000
    assert List.last(prepared.snapshots).decision_counts == prepared.run.decision_counts

    assert prepared.forecast.assumptions == [
             %{"statement" => "Managers are assumed to recognize certificates."}
           ]

    second = SimulationRunner.prepare(Demo.simulation_input(), Demo.study(), mode: "large")
    assert second.run.input_fingerprint == prepared.run.input_fingerprint
  end

  test "run pattern lookup prefers the immutable snapshot and falls back for legacy runs" do
    saved_patterns = [%{"id" => "saved", "name" => "Saved rule", "version" => 2}]
    current_patterns = [%{id: "current", name: "Current mutable rule", version: 5}]

    snapshotted_run = %SimulationRun{input_snapshot: %{"patterns" => saved_patterns}}
    legacy_run = %SimulationRun{input_snapshot: %{}}

    assert Simulations.patterns_for_run(snapshotted_run, current_patterns) == saved_patterns
    assert Simulations.patterns_for_run(legacy_run, current_patterns) == current_patterns
  end

  test "representative traces are deterministic cohort explanations, not individual ledgers" do
    input = Demo.simulation_input()
    prepared = SimulationRunner.prepare(input, Demo.study(), mode: "small")
    [first_cluster | _] = hd(prepared.snapshots).clusters["groups"]

    assert {:ok, trace} =
             RepresentativeTrace.build(
               %{seed: input.seed, scenario: %{events: input.events}},
               prepared.snapshots,
               first_cluster.representative_agent_id,
               input.patterns
             )

    assert trace.detail_level == "representative_cohort_trace"
    assert trace.representation == "deterministic_cohort_sample"
    assert trace.llm_fallback_used == false
    assert length(trace.trace) == 4
    assert Enum.all?(trace.trace, &(&1.llm_fallback_used == false))
    assert trace.parameters_disclosure =~ "does not represent a stored individual"
  end

  test "study notifications contain identifiers and state but no raw question" do
    assert Notifications.study_topic(42) == "sim_lab:study:42"
  end
end
