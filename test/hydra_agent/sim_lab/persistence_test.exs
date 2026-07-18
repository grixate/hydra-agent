defmodule HydraAgent.SimLab.PersistenceTest do
  use HydraAgent.DataCase, async: true
  use Oban.Testing, repo: HydraAgent.Repo

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Repo
  alias HydraAgent.SimLab.{Demo, Notifications, Simulations, SimulationRunner, Studies}
  alias HydraAgent.SimLab.Schemas.{ResearchRun, SimulationRun}
  alias HydraAgent.SimLab.Research.{MockWebSearchProvider, Runner}
  alias HydraAgent.SimLab.Workers.ResearchRunWorker

  test "a provider failure never replaces the active context pack" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Failure boundary",
        question: "How might people adopt a proposed change?"
      })

    assert {:ok, initial} =
             Studies.add_manual_note(study, %{note: "A retained observation grounds this pack."})

    :ok = Notifications.subscribe(study.id)
    failing_provider = fn _lane -> {:error, :provider_unavailable} end

    assert {:ok, _pid} =
             HydraAgent.SimLab.start_research(
               study,
               study.question,
               %{},
               provider: failing_provider
             )

    assert_receive {:sim_lab_update, %{kind: "research", status: "running"}}

    assert_receive {:sim_lab_update,
                    %{
                      kind: "research",
                      status: "failed",
                      reason: "provider_returned_no_evidence"
                    }}

    assert Studies.active_context_pack(study).id == initial.context_pack.id
  end

  test "provider-backed research is durable and resumes from an Oban job" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Durable research",
        question: "How might people adopt a proposed change?"
      })

    assert {:ok, %ResearchRun{status: "queued"} = run} =
             HydraAgent.SimLab.start_research(study, study.question, %{},
               provider: MockWebSearchProvider
             )

    assert run.input_snapshot["question"] == study.question
    assert_enqueued(worker: ResearchRunWorker, args: %{"research_run_id" => run.id})
    assert :ok = perform_job(ResearchRunWorker, %{"research_run_id" => run.id})

    completed = Repo.get!(ResearchRun, run.id)
    assert completed.status == "completed"
    assert completed.source_count == 7
    assert completed.completed_at
    context_pack = Studies.active_context_pack(study)
    source_ids = Enum.map(Studies.list_sources(study), & &1.id)
    evidence_ids = Enum.map(Studies.list_evidence(study), & &1.id)

    assert :ok = perform_job(ResearchRunWorker, %{"research_run_id" => run.id})
    assert Studies.active_context_pack(study).id == context_pack.id
    assert Enum.map(Studies.list_sources(study), & &1.id) == source_ids
    assert Enum.map(Studies.list_evidence(study), & &1.id) == evidence_ids
  end

  test "persists a versioned research context and compact aggregate replay" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Certificate visibility",
        question: "How will employees react to visible learning certificates?",
        domain: "Corporate learning",
        target_audience: "employees"
      })

    output =
      Runner.run(
        study.question,
        %{domain: study.domain, target_audience: study.target_audience},
        MockWebSearchProvider
      )

    assert {:ok, persisted_context} = Studies.persist_research_output(study, output)
    assert persisted_context.study.status == "context_ready"
    assert persisted_context.context_pack.version == 1
    assert persisted_context.context_pack.status == "active"
    assert length(persisted_context.sources) == 7
    assert length(Studies.list_evidence(study)) == 7

    {:ok, scenario} =
      Simulations.create_scenario(study, %{
        name: "Default visibility",
        description: "Certificates are visible in the employee profile.",
        events: Demo.study().events
      })

    prepared =
      SimulationRunner.prepare(Demo.simulation_input(), study,
        mode: "small",
        confidence: 0.62,
        assumptions: ["Visibility defaults are understood by employees."]
      )

    assert {:ok, persisted_run} =
             Simulations.persist_prepared_run(
               study,
               scenario,
               persisted_context.context_pack,
               prepared
             )

    assert persisted_run.run.status == "completed"
    assert persisted_run.report.study_id == study.id
    assert length(Simulations.replay_snapshots(persisted_run.run)) == 4
    assert length(Simulations.list_outcome_events(persisted_run.run)) <= 40
    assert length(Simulations.list_outcome_events(persisted_run.run)) > 20
    persisted_run = Simulations.get_run!(study, persisted_run.run.id)
    assert persisted_run.input_snapshot["seed"] == 713
    assert persisted_run.input_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    refute Jason.encode!(persisted_run.input_snapshot) =~ study.question
  end

  test "provider research sources can be removed with their derived evidence" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Provider source lifecycle",
        question: "How will users react to a product change?"
      })

    output = Runner.run(study.question, %{}, MockWebSearchProvider)
    assert {:ok, persisted} = Studies.persist_research_output(study, output)
    source = hd(persisted.sources)
    evidence_before = Studies.list_evidence(study)

    assert source.kind == "web"
    assert source.metadata["entry_type"] == "research"
    assert Enum.any?(evidence_before, &(&1.source_id == source.id))

    assert {:ok, %{source: removed}} = Studies.remove_local_source(study, source.id)
    assert removed.status == "deleted"
    refute Enum.any?(Studies.list_sources(study), &(&1.id == source.id))
    refute Enum.any?(Studies.list_evidence(study), &(&1.source_id == source.id))
  end

  test "a local note creates an explicit, reviewable context pack" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Manager portfolios",
        question: "How will managers use a visible learning portfolio?"
      })

    assert {:ok, result} =
             Studies.add_manual_note(study, %{
               note: "Managers already discuss portfolios during promotion cycles."
             })

    assert result.study.status == "context_ready"
    assert result.source.kind == "manual_note"
    assert result.source.pii_status == "suspected"
    assert result.evidence.grounding_level == "direct_user_data"
    assert result.context_pack.status == "active"
    assert result.context_pack.source_mix["direct_user_data"] == 1

    assert {:ok, second_result} =
             Studies.add_manual_note(study, %{
               title: "Pilot interview",
               note: "Participants asked for visibility controls before sharing portfolios."
             })

    assert second_result.source.title == "Pilot interview"
    assert second_result.context_pack.source_mix["direct_user_data"] == 2
    assert length(Studies.list_sources(study)) == 2
    assert length(Studies.list_evidence(study)) == 2

    assert {:ok, uploaded_result} =
             Studies.add_uploaded_text(study, %{
               title: "Pilot findings",
               filename: "pilot-findings.md",
               extension: ".md",
               text: "Managers want a preview before portfolio visibility is enabled."
             })

    assert uploaded_result.source.kind == "upload"
    assert uploaded_result.source.metadata["filename"] == "pilot-findings.md"
    assert uploaded_result.source.access_policy["external_send"] == false
    assert uploaded_result.context_pack.source_mix["direct_user_data"] == 3
    assert length(Studies.list_sources(study)) == 3

    assert {:ok, removed_upload} = Studies.remove_local_source(study, uploaded_result.source.id)
    assert removed_upload.source.status == "deleted"
    assert removed_upload.source.parsed_text == nil
    assert length(Studies.list_sources(study)) == 2
    assert length(Studies.list_evidence(study)) == 2
    assert removed_upload.context_pack.source_mix["direct_user_data"] == 2

    assert {:ok, _removed_second_note} =
             Studies.remove_local_source(study, second_result.source.id)

    assert {:ok, removed_first_note} = Studies.remove_local_source(study, result.source.id)
    assert removed_first_note.context_pack.summary["research_status"] == "no_local_evidence"
    assert removed_first_note.context_pack.confidence == 0.25
    assert Studies.list_sources(study) == []
    assert Studies.list_evidence(study) == []
  end

  test "a manually supplied public source becomes removable external research" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Public source",
        question: "How will people respond to new controls?"
      })

    assert {:ok, result} =
             Studies.add_public_web_source(study, %{
               uri: "https://public.example/study",
               title: "Published study",
               text: "Published evidence indicates clear controls can improve trust."
             })

    assert result.source.kind == "web"
    assert result.source.metadata["entry_type"] == "manual_public_url"
    assert result.evidence.grounding_level == "external_research"
    assert result.context_pack.source_mix["external_research"] == 1

    assert {:ok, %{source: removed}} = Studies.remove_local_source(study, result.source.id)
    assert removed.status == "deleted"
  end

  test "removing a local source invalidates linked personas and action patterns" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Evidence invalidation",
        question: "How will teams react to visible portfolios?"
      })

    {:ok, %{source: source, evidence: evidence}} =
      Studies.add_manual_note(study, %{note: "Teams expect a privacy preview before visibility."})

    {:ok, %{persona: persona}} =
      Studies.add_persona(study, %{
        name: "Privacy reviewers",
        segment: "People who need clear controls",
        distribution_weight: 1.0,
        confidence: 0.6,
        evidence_refs: [to_string(evidence.id)],
        grounding_mix: %{"direct_user_data" => 1.0}
      })

    {:ok, %{pattern: pattern}} =
      Studies.add_action_pattern(study, persona.id, %{
        name: "Ask for visibility controls",
        condition: "Visibility becomes relevant",
        interpretation: "Controls may be unclear",
        motivation: "Avoid unwanted exposure",
        likely_action: "resist",
        base_probability: 0.6,
        confidence: 0.6,
        evidence_refs: [to_string(evidence.id)],
        executable_rule: %{"origin" => "manual_review"}
      })

    assert {:ok, %{context_pack: context_pack}} = Studies.remove_local_source(study, source.id)

    [invalidated_persona] = Studies.list_personas(study)
    [invalidated_pattern] = Studies.list_action_patterns(study)

    assert invalidated_persona.evidence_refs == []
    assert invalidated_persona.grounding_mix == %{"assumption" => 1.0}
    assert invalidated_persona.version == persona.version + 1
    assert invalidated_pattern.evidence_refs == []
    assert invalidated_pattern.grounding_level == "assumption"
    assert invalidated_pattern.version == pattern.version + 1
    assert invalidated_pattern.executable_rule["grounding_invalidated"]
    assert context_pack.key_findings == []

    refute inspect([
             context_pack.key_findings,
             context_pack.market_context,
             context_pack.behavioral_context,
             context_pack.recent_context,
             context_pack.regulatory_context
           ]) =~ "privacy preview"
  end

  test "a queued simulation completes from its immutable saved input" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Durable replay",
        question: "How will employees react to a visible portfolio?"
      })

    {:ok, %{context_pack: context_pack}} =
      Studies.add_manual_note(study, %{note: "Managers want explicit controls."})

    {:ok, scenario} =
      Simulations.create_scenario(study, %{
        name: "Visible portfolio",
        description: "The portfolio becomes visible.",
        events: Demo.study().events
      })

    assert {:ok, %{run: queued_run}} =
             Simulations.queue_run(study, scenario, context_pack, Demo.simulation_input(),
               mode: "small",
               confidence: 0.55,
               assumptions: ["Control expectations remain uncertain."]
             )

    assert queued_run.status == "queued"
    assert queued_run.input_snapshot["seed"] == 713

    assert_enqueued(
      worker: HydraAgent.SimLab.Workers.SimulationRunWorker,
      args: %{run_id: queued_run.id}
    )

    assert :ok =
             perform_job(HydraAgent.SimLab.Workers.SimulationRunWorker, %{run_id: queued_run.id})

    completed_run = Simulations.get_run!(study, queued_run.id)
    assert completed_run.status == "completed"
    assert completed_run.input_fingerprint == queued_run.input_fingerprint

    assert completed_run.execution_options["assumptions"] == [
             %{"statement" => "Control expectations remain uncertain."}
           ]

    assert length(Simulations.replay_snapshots(completed_run)) == 4

    assert :ok =
             perform_job(HydraAgent.SimLab.Workers.SimulationRunWorker, %{run_id: queued_run.id})

    assert length(Simulations.replay_snapshots(completed_run)) == 4
    assert Simulations.get_run!(study, completed_run.id).forecast_report
  end

  test "a cancelled queued run never publishes snapshots or a forecast" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Cancelled replay",
        question: "How will teams respond to a new workflow?"
      })

    {:ok, %{context_pack: context_pack}} =
      Studies.add_manual_note(study, %{note: "Teams need time to adjust."})

    {:ok, scenario} =
      Simulations.create_scenario(study, %{
        name: "New workflow",
        description: "The workflow is introduced.",
        events: Demo.study().events
      })

    assert {:ok, %{run: queued_run}} =
             Simulations.queue_run(study, scenario, context_pack, Demo.simulation_input())

    assert {:ok, cancelled_run} = Simulations.cancel_run(study, queued_run.id)
    assert cancelled_run.status == "cancelled"

    assert :ok =
             perform_job(HydraAgent.SimLab.Workers.SimulationRunWorker, %{run_id: queued_run.id})

    cancelled_run = Simulations.get_run!(study, queued_run.id)
    assert cancelled_run.status == "cancelled"
    assert Simulations.replay_snapshots(cancelled_run) == []
    assert cancelled_run.forecast_report == nil
    assert :ok = Simulations.fail_run(cancelled_run.id)
    assert :ok = Simulations.execute_queued_run(cancelled_run.id)
    assert Simulations.get_run!(study, cancelled_run.id).status == "cancelled"
  end

  test "an accepted cancellation wins a deterministic race with completion" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Cancellation race",
        question: "Can a cancelled run ever publish?"
      })

    {:ok, %{context_pack: context_pack}} =
      Studies.add_manual_note(study, %{note: "Cancellation must be terminal."})

    {:ok, scenario} =
      Simulations.create_scenario(study, %{
        name: "Race boundary",
        description: "Completion and cancellation contend for one run.",
        events: Demo.study().events
      })

    input = Demo.simulation_input()

    assert {:ok, %{run: queued_run}} =
             Simulations.queue_run(study, scenario, context_pack, input)

    prepared = SimulationRunner.prepare(input, study, mode: "small")

    assert {:error, {:invalid_run_transition, "queued", "completed"}} =
             Simulations.complete_queued_run(queued_run.id, prepared)

    assert Simulations.replay_snapshots(queued_run) == []

    {:ok, running_run} =
      queued_run
      |> SimulationRun.changeset(%{status: "running", started_at: DateTime.utc_now()})
      |> Repo.update()

    parent = self()
    handler_id = "sim-lab-cancel-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:hydra_agent, :sim_lab, :run_transition, :locked],
        fn _event, _measurements, metadata, test_process ->
          if metadata.target == "cancelled" and metadata.run_id == running_run.id do
            send(test_process, {:cancellation_holds_lock, self()})

            receive do
              :release_cancellation -> :ok
            after
              5_000 -> raise "cancellation race test timed out"
            end
          end
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    cancel_task =
      Task.async(fn ->
        receive do
          :start -> Simulations.cancel_run(study, running_run.id)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), cancel_task.pid)
    send(cancel_task.pid, :start)
    assert_receive {:cancellation_holds_lock, cancellation_pid}

    completion_task =
      Task.async(fn ->
        receive do
          :start ->
            send(parent, :completion_attempted)
            Simulations.complete_queued_run(running_run.id, prepared)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), completion_task.pid)
    send(completion_task.pid, :start)
    assert_receive :completion_attempted
    assert Task.yield(completion_task, 50) == nil

    send(cancellation_pid, :release_cancellation)

    assert {:ok, %{status: "cancelled"}} = Task.await(cancel_task)
    assert :noop = Task.await(completion_task)

    cancelled_run = Simulations.get_run!(study, running_run.id)
    assert cancelled_run.status == "cancelled"
    assert Simulations.replay_snapshots(cancelled_run) == []
    assert Simulations.list_outcome_events(cancelled_run) == []
    assert cancelled_run.forecast_report == nil
  end

  test "an exhausted queued run becomes a visible failed run" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Failed replay",
        question: "How will teams respond to a new workflow?"
      })

    {:ok, %{context_pack: context_pack}} =
      Studies.add_manual_note(study, %{note: "Teams need time to adjust."})

    {:ok, scenario} =
      Simulations.create_scenario(study, %{
        name: "New workflow",
        description: "The workflow is introduced.",
        events: Demo.study().events
      })

    assert {:ok, %{run: queued_run}} =
             Simulations.queue_run(study, scenario, context_pack, Demo.simulation_input())

    {:ok, corrupted_run} =
      queued_run
      |> SimulationRun.changeset(%{input_snapshot: %{}})
      |> Repo.update()

    assert {:cancel, _reason} =
             perform_job(
               HydraAgent.SimLab.Workers.SimulationRunWorker,
               %{
                 run_id: corrupted_run.id
               },
               attempt: 3
             )

    assert Simulations.get_run!(study, corrupted_run.id).status == "failed"
    assert :ok = Simulations.execute_queued_run(corrupted_run.id)
    assert {:error, :run_not_cancellable} = Simulations.cancel_run(study, corrupted_run.id)
    assert :ok = Simulations.fail_run(corrupted_run.id)
    assert Simulations.get_run!(study, corrupted_run.id).status == "failed"
  end

  test "an assumption-only context is explicitly low-confidence and source-free" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "No-data exploration",
        question: "How might people react to a new workflow?"
      })

    assert {:ok, result} = Studies.create_assumption_context(study)
    assert result.study.status == "context_ready"
    assert result.context_pack.confidence == 0.25
    assert result.context_pack.summary["research_status"] == "assumption_start"
    assert result.context_pack.source_mix["assumptions"] == 1
    assert Studies.list_sources(study) == []
    assert {:error, :context_already_exists} = Studies.create_assumption_context(study)
  end

  test "stored workspace evidence can be synthesized into a new context version without web research" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Local context synthesis",
        question: "How will managers respond to visible portfolios?"
      })

    {:ok, %{context_pack: first_pack, evidence: evidence}} =
      Studies.add_manual_note(study, %{
        note: "Managers want a preview before portfolio visibility is enabled."
      })

    {:ok, %{context_pack: unreviewed_pack}} = Studies.synthesize_workspace_context(study)

    assert unreviewed_pack.summary["reviewed_evidence_count"] == 0
    assert unreviewed_pack.summary["unreviewed_evidence_count"] == 1
    assert unreviewed_pack.confidence == 0.33
    assert Enum.any?(unreviewed_pack.risks, &(&1["kind"] == "evidence_review_queue"))

    assert {:ok, reviewed} = Studies.review_evidence(study, evidence.id, "reviewed", 42)
    assert reviewed.metadata["review_status"] == "reviewed"
    assert reviewed.metadata["reviewer_user_id"] == 42

    {:ok, %{context_pack: synthesized}} = Studies.synthesize_workspace_context(study)

    assert first_pack.status == "active"
    assert synthesized.version == first_pack.version + 2
    assert synthesized.status == "active"
    assert synthesized.summary["research_status"] == "workspace_evidence_synthesis"
    assert synthesized.summary["synthesis_scope"] == "stored_workspace_sources_only"
    assert synthesized.source_mix["direct_user_data"] == 1
    assert synthesized.source_mix["external_research"] == 0
    assert synthesized.confidence == 0.55
    assert synthesized.summary["reviewed_evidence_count"] == 1
    assert synthesized.summary["unreviewed_evidence_count"] == 0
    assert hd(synthesized.risks)["kind"] == "scope_boundary"
    assert Studies.active_context_pack(study).id == synthesized.id

    other_workspace = workspace_fixture()

    {:ok, other_study} =
      Studies.create_study(%{
        workspace_id: other_workspace.id,
        title: "Other study",
        question: "Will another audience respond?"
      })

    assert {:error, :evidence_not_in_study} =
             Studies.review_evidence(other_study, evidence.id, "reviewed")
  end

  test "a starting behavior draft is contextual, assumption-marked, and population complete" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Starting draft",
        question: "How will people react to a new workflow?"
      })

    assert {:ok,
            %{
              generated: generated,
              persona_count: 5,
              pattern_count: 20,
              protocol_version: "sim-lab-behavior-compiler/v1"
            }} = Studies.generate_behavior_draft(study)

    assert length(generated) == 5
    assert Enum.sum_by(Studies.list_personas(study), & &1.distribution_weight) == 1.0
    assert length(Studies.list_action_patterns(study)) == 20

    assert Enum.all?(Studies.list_personas(study), fn persona ->
             persona.segment =~ "target users" and persona.goals != [] and
               persona.frictions != [] and persona.triggers != [] and
               persona.trust_factors != [] and persona.likely_actions != [] and
               persona.grounding_mix == %{"assumption" => 1.0} and persona.evidence_refs == [] and
               persona.assumption_refs != [] and persona.confidence <= 0.34
           end)

    assert Enum.all?(Studies.list_action_patterns(study), fn pattern ->
             pattern.condition =~ "proposed product change" and pattern.blockers != [] and
               pattern.amplifiers != [] and pattern.state_updates != %{} and
               pattern.evidence_refs == [] and pattern.assumption_refs != [] and
               pattern.executable_rule["protocol_version"] ==
                 "sim-lab-behavior-compiler/v1" and
               pattern.executable_rule["population_share"] == 0.25
           end)

    assert {:error, :personas_already_exist} = Studies.generate_behavior_draft(study)
  end

  test "a behavior draft distributes stored evidence without hiding assumption priors" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Evidence-linked draft",
        question: "How will managers respond to visible learning portfolios?",
        domain: "workforce learning",
        target_audience: "managers"
      })

    assert {:ok, %{evidence: evidence}} =
             Studies.add_manual_note(study, %{
               note: "Managers want explicit visibility controls before sharing portfolios."
             })

    assert {:ok, _reviewed} = Studies.review_evidence(study, evidence.id, "reviewed")

    assert {:ok, %{persona_count: 5, pattern_count: 20}} =
             Studies.generate_behavior_draft(study)

    evidence_ref = to_string(evidence.id)

    assert Enum.all?(Studies.list_personas(study), fn persona ->
             persona.evidence_refs == [evidence_ref] and persona.assumption_refs != [] and
               persona.grounding_mix == %{"assumption" => 0.3, "direct_user_data" => 0.7} and
               persona.confidence < 0.63
           end)

    assert Enum.all?(Studies.list_action_patterns(study), fn pattern ->
             pattern.evidence_refs == [evidence_ref] and pattern.assumption_refs != [] and
               pattern.grounding_level == "direct_user_data" and pattern.confidence < 0.63
           end)
  end

  test "scenario compiler creates reviewable variants without hidden numeric effects" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Portfolio visibility",
        question: "How will employees react if learning portfolios become visible?",
        domain: "Workforce learning",
        target_audience: "employees",
        region: "Germany",
        timeframe: "60 days"
      })

    assert {:ok, %{base: base, variants: variants, generated: generated}} =
             Simulations.generate_scenario_draft(study, nil)

    assert length(generated) == 3
    assert length(variants) == 2
    assert base.name =~ "Portfolio visibility"
    assert base.forecast_horizon == "60 days"
    assert base.description == study.question
    assert Enum.all?(variants, &(&1.variant_of_id == base.id))

    assert Enum.all?(generated, fn scenario ->
             scenario.available_actions == ~w(adopt resist ignore share) and
               scenario.metadata["generated_by_protocol_version"] ==
                 "sim-lab-scenario-compiler/v1" and
               scenario.metadata["numeric_effects"] == "none_until_researcher_review" and
               Enum.all?(scenario.events, &(&1["action_effects"] == %{}))
           end)

    assert {:error, :scenarios_already_exist} =
             Simulations.generate_scenario_draft(study, nil)
  end

  test "behavior segments cannot allocate more than the study population" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Portfolio visibility",
        question: "How will people react to a visible portfolio?"
      })

    assert {:ok, first} =
             Studies.add_persona(study, %{
               name: "Careful planners",
               segment: "Risk-conscious managers",
               distribution_weight: 0.7,
               goals: ["Avoid surprises"],
               frictions: ["Default visibility"],
               confidence: 0.55,
               grounding_mix: %{"assumption" => 1.0}
             })

    assert first.study.status == "personas_ready"
    assert first.allocated_weight == 0.7

    assert {:error, :distribution_exceeds_population} =
             Studies.add_persona(study, %{
               name: "Growth seekers",
               segment: "Career-oriented managers",
               distribution_weight: 0.4,
               confidence: 0.55,
               grounding_mix: %{"assumption" => 1.0}
             })

    assert [%{name: "Careful planners"}] = Studies.list_personas(study)
  end

  test "an action pattern is scoped to a persona in the same study" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Visible portfolios",
        question: "What happens when portfolios are visible?"
      })

    {:ok, %{persona: persona}} =
      Studies.add_persona(study, %{
        name: "Growth seekers",
        segment: "Career-focused managers",
        distribution_weight: 0.4,
        confidence: 0.55,
        grounding_mix: %{"assumption" => 1.0}
      })

    assert {:ok, result} =
             Studies.add_action_pattern(study, persona.id, %{
               name: "Portfolio signaling",
               condition: "Portfolio is visible by default",
               interpretation: "Visible work can signal growth",
               motivation: "Make achievement visible",
               likely_action: "adopt",
               base_probability: 0.62,
               confidence: 0.55,
               evidence_refs: [],
               assumption_refs: ["manual_pattern"],
               executable_rule: %{"origin" => "manual_pattern"}
             })

    assert result.study.status == "patterns_ready"
    assert result.pattern.persona_ids == [persona.id]
    assert [%{name: "Portfolio signaling"}] = Studies.list_action_patterns(study)
  end

  test "behavior revisions are versioned and stay within their study" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Reviewable behavior",
        question: "What makes managers adopt a new portfolio?"
      })

    {:ok, %{evidence: evidence}} =
      Studies.add_manual_note(study, %{note: "Managers value clear privacy controls."})

    {:ok, %{persona: persona}} =
      Studies.add_persona(study, %{
        name: "Careful planners",
        segment: "Risk-conscious managers",
        distribution_weight: 0.4,
        confidence: 0.5,
        grounding_mix: %{"assumption" => 1.0}
      })

    assert {:ok, %{persona: revised_persona, allocated_weight: 0.45}} =
             Studies.update_persona(study, persona.id, %{
               name: "Careful reviewers",
               distribution_weight: 0.45,
               triggers: ["A manager asks for visibility"],
               trust_factors: ["Clear privacy controls"],
               likely_actions: ["resist"],
               editable_notes: "Review after the first pilot.",
               evidence_refs: [to_string(evidence.id)]
             })

    assert revised_persona.version == 2
    assert revised_persona.name == "Careful reviewers"
    assert revised_persona.triggers == ["A manager asks for visibility"]
    assert revised_persona.evidence_refs == [to_string(evidence.id)]
    assert revised_persona.grounding_mix == %{"direct_user_data" => 1.0}

    {:ok, %{pattern: pattern}} =
      Studies.add_action_pattern(study, revised_persona.id, %{
        name: "Control before sharing",
        condition: "The portfolio is visible by default",
        interpretation: "Visibility feels like unwanted exposure",
        motivation: "Avoid surprises",
        likely_action: "resist",
        base_probability: 0.62,
        confidence: 0.55,
        evidence_refs: [],
        assumption_refs: ["manual_pattern"],
        executable_rule: %{"origin" => "manual_pattern"}
      })

    assert {:ok, %{pattern: revised_pattern}} =
             Studies.update_action_pattern(study, pattern.id, revised_persona.id, %{
               name: "Control before sharing · revised",
               condition: "Privacy controls are unclear",
               interpretation: "Visibility is reassessed as surveillance",
               motivation: "Avoid unexpected exposure",
               likely_action: "resist",
               base_probability: 0.7,
               confidence: 0.6,
               blockers: [%{"statement" => "No clear settings"}],
               amplifiers: [%{"statement" => "Manager recognition"}],
               executable_rule: %{"origin" => "manual_review"},
               evidence_refs: [to_string(evidence.id)]
             })

    assert revised_pattern.version == 2
    assert revised_pattern.persona_ids == [revised_persona.id]
    assert revised_pattern.blockers == [%{"statement" => "No clear settings"}]
    assert revised_pattern.evidence_refs == [to_string(evidence.id)]
    assert revised_pattern.grounding_level == "direct_user_data"

    other_workspace = workspace_fixture()

    {:ok, other_study} =
      Studies.create_study(%{
        workspace_id: other_workspace.id,
        title: "Other study",
        question: "What is unrelated evidence?"
      })

    {:ok, %{evidence: other_evidence}} =
      Studies.add_manual_note(other_study, %{note: "This evidence belongs elsewhere."})

    assert {:error, :evidence_not_in_study} =
             Studies.update_persona(study, revised_persona.id, %{
               evidence_refs: [to_string(other_evidence.id)]
             })
  end

  test "a scenario can be duplicated as a linked variant" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Variants",
        question: "Which launch framing works better?"
      })

    {:ok, base} =
      Simulations.create_scenario(study, %{
        name: "Visible by default",
        description: "The portfolio appears by default.",
        events: [%{"day" => "1", "title" => "Announcement"}]
      })

    assert {:ok, variant} = Simulations.create_variant(study, base)
    assert variant.variant_of_id == base.id
    assert variant.events == base.events
    assert variant.name == "Visible by default · Variant"

    assert {:ok, refined_variant} =
             Simulations.update_scenario(study, variant.id, %{
               name: "Opt-in portfolio framing",
               description: "The portfolio is opt-in and framed as a career record.",
               forecast_horizon: "45 days",
               events: [
                 %{
                   "day" => "1",
                   "title" => "Opt-in announcement",
                   "impact" => "Control is explicit."
                 }
               ],
               success_metrics: ["opt-in adoption"]
             })

    assert refined_variant.name == "Opt-in portfolio framing"
    assert refined_variant.metadata["refined_in_workspace"]
  end

  test "stored study records compile into a coverage-aware aggregate run" do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Portfolio visibility",
        question: "What happens when portfolios are visible?"
      })

    {:ok, %{context_pack: context_pack}} =
      Studies.add_manual_note(study, %{note: "Managers already value visible achievement."})

    {:ok, %{persona: persona}} =
      Studies.add_persona(study, %{
        name: "Growth seekers",
        segment: "Career-focused managers",
        distribution_weight: 0.6,
        confidence: 0.55,
        grounding_mix: %{"assumption" => 1.0}
      })

    {:ok, %{pattern: pattern}} =
      Studies.add_action_pattern(study, persona.id, %{
        name: "Portfolio signaling",
        condition: "Portfolio is visible",
        interpretation: "Visibility signals achievement",
        motivation: "Make growth visible",
        likely_action: "adopt",
        base_probability: 0.62,
        confidence: 0.55,
        evidence_refs: [],
        assumption_refs: ["manual_pattern"],
        executable_rule: %{"origin" => "manual_pattern"}
      })

    {:ok, scenario} =
      Simulations.create_scenario(study, %{
        name: "Visible by default",
        description: "The portfolio appears in manager profiles.",
        events: [
          %{"day" => "1", "title" => "Announcement"},
          %{"day" => "14", "title" => "First use"}
        ]
      })

    assert {:ok, compiled} =
             HydraAgent.SimLab.build_simulation_input(
               Studies.list_personas(study),
               Studies.list_action_patterns(study),
               scenario,
               mode: "small"
             )

    assert compiled.coverage.modeled_population == 0.6
    assert compiled.coverage.unmodelled_population == 0.4
    assert Enum.any?(compiled.input.personas, &(&1.id == "unmodelled-remainder"))

    assert {:ok, persisted_run} =
             Simulations.execute(study, scenario, context_pack, compiled.input,
               mode: "small",
               confidence: 0.49,
               assumptions: ["40% of the population remains unmodelled."]
             )

    assert persisted_run.run.agent_count == 250
    assert persisted_run.run.status == "completed"

    assert persisted_run.report.assumptions == [
             %{"statement" => "40% of the population remains unmodelled."}
           ]

    assert persisted_run.report.evidence_map == %{
             "direct_user_data" => 1,
             "external_research" => 0,
             "assumptions" => 1
           }

    assert {:error, :scenario_has_runs} =
             Simulations.update_scenario(study, scenario.id, %{
               name: "Retrospectively changed scenario",
               description: "This must not rewrite a completed run."
             })

    assert length(Simulations.replay_snapshots(persisted_run.run)) == 2

    assert {:error, :invalid_calibration} =
             HydraAgent.SimLab.record_calibration(study, persisted_run.run, %{
               metric: "adopt",
               actual_value: "0.42 points"
             })

    assert {:ok, calibration} =
             HydraAgent.SimLab.record_calibration(study, persisted_run.run, %{
               metric: "adopt",
               actual_value: "0.10",
               note: "Observed after four weeks."
             })

    assert calibration.forecast_value == persisted_run.run.aggregate_metrics["adopt"]
    assert calibration.actual_value == 0.10
    assert calibration.delta == Float.round(0.10 - calibration.forecast_value, 4)

    {:ok, %{pattern: post_run_pattern}} =
      Studies.add_action_pattern(study, persona.id, %{
        name: "Later adoption theory",
        condition: "A later idea is proposed",
        interpretation: "This rule was not available to the completed run",
        motivation: "Test a future hypothesis",
        likely_action: "adopt",
        base_probability: 0.5,
        confidence: 0.5,
        evidence_refs: [],
        assumption_refs: ["post_run_pattern"],
        executable_rule: %{"origin" => "post_run_pattern"}
      })

    [proposal] = HydraAgent.SimLab.Calibrations.proposals(study, persisted_run.run)
    assert proposal.pattern_id == pattern.id
    assert proposal.metric == "adopt"
    assert proposal.suggested_confidence < proposal.current_confidence

    assert {:ok, calibrated_pattern} =
             HydraAgent.SimLab.Calibrations.apply_proposal(study, persisted_run.run, pattern.id)

    assert calibrated_pattern.version == pattern.version + 1
    assert calibrated_pattern.confidence == proposal.suggested_confidence
    assert calibrated_pattern.executable_rule["calibration_record_id"] == calibration.id
    assert HydraAgent.SimLab.Calibrations.proposals(study, persisted_run.run) == []

    assert {:error, :no_calibration_proposal} =
             HydraAgent.SimLab.Calibrations.apply_proposal(
               study,
               persisted_run.run,
               post_run_pattern.id
             )

    assert {:error, :no_calibration_proposal} =
             HydraAgent.SimLab.Calibrations.apply_proposal(
               study,
               persisted_run.run,
               calibrated_pattern.id
             )
  end
end
