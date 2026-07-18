defmodule HydraAgent.AuditTest do
  use HydraAgent.DataCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{Audit, MCP, Repo, Runtime}
  alias HydraAgent.SimLab.SimulationRunner

  alias HydraAgent.SimLab.Schemas.{
    ActionPattern,
    CalibrationRecord,
    ContextPack,
    EvidenceItem,
    ForecastReport,
    OutcomeEvent,
    Persona,
    ResearchRun,
    Scenario,
    SimulationRun,
    SimulationSnapshot,
    Source,
    Study
  }

  test "exports tool bundles, policy bundle grants, and MCP server refs" do
    workspace = workspace_fixture()

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        tool_bundles: ["files_read"],
        filesystem_allowlist: ["lib"],
        shell_env_allowlist: ["HYDRA_TEST_FLAG"],
        requires_approval: false
      })

    {:ok, _server} =
      MCP.create_server(%{
        workspace_id: workspace.id,
        name: "Docs MCP",
        slug: "docs-mcp-audit",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        env_refs: ["MCP_DOCS_TOKEN"],
        include_tools: ["search_docs"]
      })

    export = Audit.export_workspace(workspace.id)

    assert Enum.any?(export["tool_bundles"], &(&1.name == "files_read"))

    assert [%{"tool_bundles" => ["files_read"], "shell_env_allowlist" => ["HYDRA_TEST_FLAG"]}] =
             export["tool_policies"]

    assert [
             %{
               "slug" => "docs-mcp-audit",
               "env_refs" => ["MCP_DOCS_TOKEN"],
               "include_tools" => ["search_docs"]
             }
           ] = export["mcp_servers"]
  end

  test "exports deterministic workspace-scoped SimLab lifecycle and provenance" do
    workspace = workspace_fixture()
    other_workspace = workspace_fixture()

    included = sim_lab_lifecycle_fixture(workspace, "included")
    earlier = sim_lab_lifecycle_fixture(workspace, "earlier")
    excluded = sim_lab_lifecycle_fixture(other_workspace, "excluded")

    sim_lab = Audit.export_workspace(workspace.id)["sim_lab"]

    assert Enum.map(sim_lab["studies"], & &1["id"]) ==
             Enum.sort([included.study.id, earlier.study.id])

    assert_section_ids(sim_lab, included, earlier)

    refute Enum.any?(sim_lab["studies"], &(&1["id"] == excluded.study.id))
    refute Enum.any?(sim_lab["sources"], &(&1["id"] == excluded.source.id))
    refute Enum.any?(sim_lab["evidence_items"], &(&1["id"] == excluded.evidence.id))
    refute Enum.any?(sim_lab["context_packs"], &(&1["id"] == excluded.context_pack.id))
    refute Enum.any?(sim_lab["personas"], &(&1["id"] == excluded.persona.id))
    refute Enum.any?(sim_lab["action_patterns"], &(&1["id"] == excluded.pattern.id))
    refute Enum.any?(sim_lab["scenarios"], &(&1["id"] == excluded.scenario.id))
    refute Enum.any?(sim_lab["simulation_runs"], &(&1["id"] == excluded.run.id))
    refute Enum.any?(sim_lab["snapshots"], &(&1["id"] == excluded.snapshot.id))
    refute Enum.any?(sim_lab["outcome_events"], &(&1["id"] == excluded.outcome.id))
    refute Enum.any?(sim_lab["forecast_reports"], &(&1["id"] == excluded.report.id))
    refute Enum.any?(sim_lab["calibrations"], &(&1["id"] == excluded.calibration.id))
    refute Enum.any?(sim_lab["research_runs"], &(&1["id"] == excluded.research_run.id))
  end

  test "omits raw SimLab source content while retaining hashes and safe provenance" do
    workspace = workspace_fixture()
    lifecycle = sim_lab_lifecycle_fixture(workspace, "privacy")

    sim_lab = Audit.export_workspace(workspace.id)["sim_lab"]
    encoded = Jason.encode!(sim_lab)
    secret = lifecycle.secret

    refute encoded =~ secret
    refute encoded =~ lifecycle.raw_object_key
    refute encoded =~ lifecycle.markdown_body
    refute encoded =~ lifecycle.calibration_note
    refute encoded =~ lifecycle.research_question
    refute encoded =~ "private-download-token"

    assert [source] = sim_lab["sources"]
    refute Map.has_key?(source, "parsed_text")
    refute Map.has_key?(source, "raw_object_key")
    assert source["content_hash"] == lifecycle.source.content_hash
    assert source["metadata"] == %{"entry_type" => "uploaded_text", "filename" => "notes.txt"}
    assert source["uri"] == "https://research.example.test/notes"
    assert is_binary(source["uri_hash"])
    assert is_binary(source["metadata_fingerprint"])

    assert [evidence] = sim_lab["evidence_items"]
    refute Map.has_key?(evidence, "claim")
    refute Map.has_key?(evidence, "normalized_claim")
    assert is_binary(evidence["claim_hash"])
    assert is_binary(evidence["normalized_claim_hash"])

    assert [context_pack] = sim_lab["context_packs"]
    refute Map.has_key?(context_pack, "key_findings")
    assert context_pack["section_counts"]["key_findings"] == 1
    assert is_binary(context_pack["content_fingerprint"])

    assert [persona] = sim_lab["personas"]
    refute Map.has_key?(persona, "editable_notes")
    assert is_binary(persona["editable_notes_hash"])

    assert [report] = sim_lab["forecast_reports"]
    refute Map.has_key?(report, "markdown_body")
    refute Map.has_key?(report, "export_object_key")
    assert is_binary(report["content_fingerprint"])

    assert [calibration] = sim_lab["calibrations"]
    refute Map.has_key?(calibration, "note")
    assert is_binary(calibration["note_hash"])

    assert [research_run] = sim_lab["research_runs"]
    refute Map.has_key?(research_run, "input_snapshot")
    assert is_binary(research_run["input_fingerprint"])

    assert [simulation_run] = sim_lab["simulation_runs"]
    refute Map.has_key?(simulation_run, "input_snapshot")
    assert simulation_run["input_fingerprint"] == lifecycle.run.input_fingerprint
  end

  test "exports workspace-scoped Simulation Studio lineage without raw attachments" do
    workspace = workspace_fixture(%{name: "Audit Studio", slug: "audit-studio"})
    other = workspace_fixture(%{name: "Audit Other", slug: "audit-other"})
    [general | _] = HydraAgent.Simulations.Blueprints.ensure_builtins!()
    secret_note = "private-studio-note"
    secret_file = "private,file\nsecret,value"

    inputs = %{
      "notes" => secret_note,
      "urls" => [%{"uri" => "https://research.example.test/context", "status" => "pending"}],
      "files" => [
        %{
          "filename" => "private.csv",
          "extension" => ".csv",
          "media_type" => "text/csv",
          "size_bytes" => byte_size(secret_file),
          "sha256" => sha256_for_test(secret_file),
          "text" => secret_file
        }
      ]
    }

    {:ok, included} =
      HydraAgent.Simulations.create_simulation(workspace, nil, %{
        "question" => "How might a private input alter modeled behavior?",
        "blueprint_id" => general.id,
        "inputs" => inputs
      })

    {:ok, excluded} =
      HydraAgent.Simulations.create_simulation(other, nil, %{
        "question" => "How might another workspace remain isolated?",
        "blueprint_id" => general.id
      })

    type_id = hd(included.active_population_model.agent_types)["id"]
    imported_secret = "private-imported-population-value"

    {:ok, population_import} =
      HydraAgent.Simulations.import_population(
        included,
        nil,
        "private-population.csv",
        "id,type,attribute_private_note\nprivate-agent,#{type_id},#{imported_secret}\n"
      )

    [representative | _] = population_import.population_model.compile_summary["representatives"]

    {:ok, %{projection: projection}} =
      HydraAgent.Simulations.generate_persona_projection(
        population_import.simulation,
        representative["agent_id"],
        nil
      )

    studio = Audit.export_workspace(workspace.id)["simulation_studio"]
    encoded = Jason.encode!(studio)

    assert Enum.map(studio["simulations"], & &1["id"]) == [included.id]
    refute Enum.any?(studio["simulations"], &(&1["id"] == excluded.id))
    assert Enum.count(studio["blueprints"], & &1["built_in"]) == 2
    assert length(studio["build_stages"]) == 6
    assert length(studio["context_packs"]) == 1
    assert length(studio["population_models"]) == 2
    assert length(studio["persona_projections"]) == 1

    [version] = studio["simulation_versions"]
    assert version["content_hash"] == included.active_version.content_hash

    assert version["input_summary"]["notes_fingerprint"] ==
             audit_fingerprint_for_test(secret_note)

    assert [%{"filename" => "private.csv", "sha256" => file_hash}] =
             version["input_summary"]["files"]

    assert file_hash == sha256_for_test(secret_file)

    [context_pack] = studio["context_packs"]
    assert context_pack["id"] == included.active_context_pack.id
    assert context_pack["content_hash"] == included.active_context_pack.content_hash
    assert is_binary(context_pack["interpretation"]["primary_question_fingerprint"])
    assert Enum.any?(context_pack["sources"], &is_binary(&1["excerpt_fingerprint"]))
    assert Enum.all?(context_pack["claims"], &is_binary(&1["statement_fingerprint"]))
    assert Enum.all?(context_pack["assumptions"], &is_binary(&1["statement_fingerprint"]))
    refute Enum.any?(context_pack["sources"], &Map.has_key?(&1, "excerpt"))
    refute Enum.any?(context_pack["claims"], &Map.has_key?(&1, "statement"))
    refute Enum.any?(context_pack["assumptions"], &Map.has_key?(&1, "statement"))

    refute encoded =~ secret_note
    refute encoded =~ secret_file
    refute encoded =~ imported_secret
    refute encoded =~ projection.prose
    refute encoded =~ "\"text\""

    [first_population, active_population] = studio["population_models"]
    assert first_population["id"] == included.active_population_model.id
    assert active_population["id"] == population_import.population_model.id
    assert active_population["imported_agent_count"] == 1
    assert is_binary(active_population["imported_agents_fingerprint"])
    assert is_binary(active_population["compile_summary"]["representatives_fingerprint"])
    refute Map.has_key?(active_population, "imported_agents")

    [audited_projection] = studio["persona_projections"]
    assert audited_projection["id"] == projection.id
    assert is_binary(audited_projection["prose_fingerprint"])
    refute Map.has_key?(audited_projection, "prose")

    [audited_simulation] = studio["simulations"]

    assert audited_simulation["active_population_model_id"] ==
             population_import.population_model.id
  end

  defp assert_section_ids(sim_lab, first, second) do
    sections = [
      {"sources", :source},
      {"evidence_items", :evidence},
      {"context_packs", :context_pack},
      {"personas", :persona},
      {"action_patterns", :pattern},
      {"scenarios", :scenario},
      {"simulation_runs", :run},
      {"snapshots", :snapshot},
      {"outcome_events", :outcome},
      {"forecast_reports", :report},
      {"calibrations", :calibration},
      {"research_runs", :research_run}
    ]

    Enum.each(sections, fn {section, field} ->
      expected = Enum.sort([Map.fetch!(first, field).id, Map.fetch!(second, field).id])
      assert Enum.map(sim_lab[section], & &1["id"]) == expected
    end)
  end

  defp sha256_for_test(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp audit_fingerprint_for_test(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sim_lab_lifecycle_fixture(workspace, suffix) do
    secret = "raw-source-secret-#{suffix}"
    raw_object_key = "private/object/#{suffix}"
    markdown_body = "private-report-markdown-#{suffix}"
    calibration_note = "private-calibration-note-#{suffix}"
    research_question = "private-research-question-#{suffix}"

    study =
      %Study{}
      |> Study.changeset(%{
        workspace_id: workspace.id,
        title: "Audit study #{suffix}",
        question: "Will the proposed change be adopted?",
        domain: "productivity",
        region: "Global",
        language: "English",
        timeframe: "90 days",
        target_audience: "Knowledge workers",
        desired_outcomes: %{"adopt" => true},
        status: "completed"
      })
      |> Repo.insert!()

    source =
      %Source{}
      |> Source.changeset(%{
        workspace_id: workspace.id,
        study_id: study.id,
        kind: "upload",
        title: "Private notes #{suffix}",
        uri: "https://research.example.test/notes?token=private-download-token##{suffix}",
        content_hash: "sha256:#{suffix}",
        raw_object_key: raw_object_key,
        parsed_text: secret,
        metadata: %{
          "entry_type" => "uploaded_text",
          "filename" => "notes.txt",
          "raw_excerpt" => secret
        },
        pii_status: "suspected",
        access_policy: %{
          "scope" => "workspace_only",
          "external_send" => false,
          "raw_note" => secret
        },
        status: "parsed"
      })
      |> Repo.insert!()

    evidence =
      %EvidenceItem{}
      |> EvidenceItem.changeset(%{
        study_id: study.id,
        source_id: source.id,
        kind: "uploaded_data",
        claim: secret,
        normalized_claim: String.downcase(secret),
        source_ref: %{
          "source_id" => to_string(source.id),
          "kind" => "upload",
          "raw_excerpt" => secret
        },
        grounding_level: "direct_user_data",
        reliability_score: 0.8,
        relevance_score: 0.9,
        freshness_score: 0.7,
        confidence_score: 0.75,
        simulation_impact: "May increase adoption.",
        tags: ["uploaded_text"],
        metadata: %{"review_status" => "reviewed", "raw_excerpt" => secret}
      })
      |> Repo.insert!()

    context_pack =
      %ContextPack{}
      |> ContextPack.changeset(%{
        study_id: study.id,
        version: 1,
        summary: %{"research_status" => "complete", "raw_summary" => secret},
        source_mix: %{"direct_user_data" => 1},
        key_findings: [%{"statement" => secret, "source_id" => source.id}],
        assumptions: [%{"statement" => "Directional forecast"}],
        confidence: 0.75,
        generated_by_protocol_version: "audit-test/v1",
        status: "active"
      })
      |> Repo.insert!()

    persona =
      %Persona{}
      |> Persona.changeset(%{
        study_id: study.id,
        name: "Careful evaluator #{suffix}",
        segment: "Evaluates evidence before adoption",
        distribution_weight: 1.0,
        goals: ["Reduce uncertainty"],
        frictions: ["Low trust"],
        likely_actions: ["adopt", "resist"],
        behavioral_parameters: %{"trust" => 0.7},
        evidence_refs: [to_string(evidence.id)],
        grounding_mix: %{"direct_user_data" => 1},
        confidence: 0.75,
        editable_notes: secret,
        status: "active"
      })
      |> Repo.insert!()

    pattern =
      %ActionPattern{}
      |> ActionPattern.changeset(%{
        study_id: study.id,
        name: "Evidence builds trust #{suffix}",
        persona_ids: [persona.id],
        condition: "Evidence is clear",
        interpretation: "The change appears credible",
        motivation: "Reduce uncertainty",
        likely_action: "adopt",
        base_probability: 0.7,
        grounding_level: "direct_user_data",
        evidence_refs: [to_string(evidence.id)],
        confidence: 0.75,
        executable_rule: %{"probability" => 0.7},
        status: "active"
      })
      |> Repo.insert!()

    scenario =
      %Scenario{}
      |> Scenario.changeset(%{
        study_id: study.id,
        name: "Launch #{suffix}",
        description: "Release the proposed experience.",
        forecast_horizon: "90 days",
        events: [%{"tick" => 1, "type" => "launch"}],
        available_actions: ["adopt", "resist", "ignore", "share"],
        success_metrics: ["adopt"],
        constraints: ["directional_only"],
        metadata: %{"audit" => true}
      })
      |> Repo.insert!()

    input_snapshot = %{
      "personas" => [%{"id" => persona.id, "version" => persona.version}],
      "patterns" => [%{"id" => pattern.id, "version" => pattern.version}],
      "events" => scenario.events,
      "agent_count" => 100,
      "seed" => 41
    }

    run =
      %SimulationRun{}
      |> SimulationRun.changeset(%{
        study_id: study.id,
        scenario_id: scenario.id,
        context_pack_id: context_pack.id,
        mode: "small",
        agent_count: 100,
        rounds: 1,
        seed: 41,
        status: "completed",
        budget_cap_usd: Decimal.new("2.00"),
        actual_cost_usd: Decimal.new("0.20"),
        decision_counts: %{"adopt" => 70, "resist" => 30},
        aggregate_metrics: %{"adopt" => 0.7, "resist" => 0.3},
        input_snapshot: input_snapshot,
        input_fingerprint: SimulationRunner.input_fingerprint(input_snapshot),
        execution_options: %{"mode" => "small"},
        confidence: 0.75,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    snapshot =
      %SimulationSnapshot{}
      |> SimulationSnapshot.changeset(%{
        run_id: run.id,
        tick: 1,
        label: "Launch",
        clusters: %{"groups" => []},
        metrics: %{"adopt" => 0.7},
        decision_counts: %{"adopt" => 70},
        cost: %{"actual_usd" => 0.2},
        insight_refs: ["event:launch"]
      })
      |> Repo.insert!()

    outcome =
      %OutcomeEvent{}
      |> OutcomeEvent.changeset(%{
        run_id: run.id,
        tick: 1,
        persona_id: to_string(persona.id),
        action_pattern: pattern.name,
        action: "adopt",
        probability: 0.7,
        confidence: 0.75,
        state_delta: %{"trust" => 0.1},
        metadata: %{"aggregate_count" => 70}
      })
      |> Repo.insert!()

    report =
      %ForecastReport{}
      |> ForecastReport.changeset(%{
        run_id: run.id,
        study_id: study.id,
        title: "Forecast #{suffix}",
        executive_summary: "Adoption is directionally more likely than resistance.",
        outcome_probabilities: %{"adopt" => 0.7, "resist" => 0.3},
        segment_reactions: [],
        behavior_drivers: [%{"driver" => "Evidence quality"}],
        resistance_drivers: [%{"driver" => "Low trust"}],
        evidence_map: %{"direct_user_data" => 1},
        assumptions: [%{"statement" => "Directional only"}],
        uncertainty: %{"confidence" => 0.75},
        validation_recommendations: ["Measure observed adoption"],
        markdown_body: markdown_body,
        export_object_key: "private/report/#{suffix}"
      })
      |> Repo.insert!()

    calibration =
      %CalibrationRecord{}
      |> CalibrationRecord.changeset(%{
        study_id: study.id,
        run_id: run.id,
        metric: "adopt",
        forecast_value: 0.7,
        actual_value: 0.65,
        delta: -0.05,
        note: calibration_note,
        observed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    research_run =
      %ResearchRun{}
      |> ResearchRun.changeset(%{
        workspace_id: workspace.id,
        study_id: study.id,
        provider: "mock",
        status: "completed",
        input_snapshot: %{
          "question" => research_question,
          "private_entities" => [secret]
        },
        source_count: 1,
        failed_lanes: 0,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{
      study: study,
      source: source,
      evidence: evidence,
      context_pack: context_pack,
      persona: persona,
      pattern: pattern,
      scenario: scenario,
      run: run,
      snapshot: snapshot,
      outcome: outcome,
      report: report,
      calibration: calibration,
      research_run: research_run,
      secret: secret,
      raw_object_key: raw_object_key,
      markdown_body: markdown_body,
      calibration_note: calibration_note,
      research_question: research_question
    }
  end
end
