defmodule HydraAgent.SkillsTest do
  use HydraAgent.DataCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Rooms.Message
  alias HydraAgent.{Evals, Repo, Rooms, Runtime, Skills}
  alias HydraAgent.Skills.LearningWorker

  test "create_skill records an initial version snapshot" do
    workspace = workspace_fixture(%{slug: "skills-version-create"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Runtime Triage",
        slug: "runtime-triage-version-create",
        description: "Inspect stuck runs.",
        instructions: "Check worker state and approvals.",
        required_tools: ["knowledge_read"]
      })

    assert [version] = Skills.list_versions(skill)
    assert version.version == 1
    assert version.change_kind == "created"
    assert version.status == "proposed"
    assert version.snapshot["name"] == "Runtime Triage"
    assert version.snapshot["required_tools"] == ["knowledge_read"]
  end

  test "lifecycle transitions append ordered versions" do
    workspace = workspace_fixture(%{slug: "skills-version-lifecycle"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Memory Review",
        slug: "memory-review-version-lifecycle",
        description: "Review memory proposals.",
        instructions: "Check provenance before approval."
      })

    {:ok, testing} = Skills.test_skill(skill)
    {:ok, active} = Skills.activate_skill(testing)
    {:ok, deprecated} = Skills.deprecate_skill(active)
    {:ok, _archived} = Skills.archive_skill(deprecated)

    assert [
             %{version: 5, change_kind: "archived", status: "archived"},
             %{version: 4, change_kind: "deprecated", status: "deprecated"},
             %{version: 3, change_kind: "active", status: "active"},
             %{version: 2, change_kind: "testing", status: "testing"},
             %{version: 1, change_kind: "created", status: "proposed"}
           ] = Skills.list_versions(skill)
  end

  test "activate_skill requires thresholded eval suites to pass" do
    workspace = workspace_fixture(%{slug: "skills-activation-gate"})

    agent =
      agent_fixture(workspace, %{
        slug: "skills-activation-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-1"
      })

    {:ok, suite} =
      Evals.create_suite(%{
        workspace_id: workspace.id,
        name: "Activation Eval",
        slug: "activation-eval"
      })

    {:ok, _case} =
      Evals.create_case(suite, %{
        name: "Requires mock",
        slug: "requires-mock",
        prompt: "hello",
        expected: %{"contains" => ["mock"]}
      })

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Thresholded Skill",
        slug: "thresholded-skill",
        description: "Must pass evals.",
        instructions: "Use only after evals pass.",
        evals: %{"suite_id" => suite.slug, "threshold" => 0.9}
      })

    assert {:error, changeset} = Skills.activate_skill(skill)

    assert {"activation requires at least one eval run for the attached suite", _meta} =
             changeset.errors[:evals]

    {:ok, run} =
      Evals.create_run(%{
        workspace_id: workspace.id,
        suite_id: suite.id,
        agent_id: agent.id
      })

    {:ok, _run} = Evals.execute_run(run)

    assert {:ok, active} = Skills.activate_skill(Skills.get_skill!(skill.id))
    assert active.status == "active"
  end

  test "activate_skill blocks thresholded skills when latest eval pass rate is low" do
    workspace = workspace_fixture(%{slug: "skills-activation-gate-failure"})

    agent =
      agent_fixture(workspace, %{
        slug: "skills-activation-failure-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-1"
      })

    {:ok, suite} =
      Evals.create_suite(%{
        workspace_id: workspace.id,
        name: "Activation Failure Eval",
        slug: "activation-failure-eval"
      })

    {:ok, _case} =
      Evals.create_case(suite, %{
        name: "Requires refusal",
        slug: "requires-refusal",
        prompt: "hello",
        expected: %{"contains" => ["cannot comply"]}
      })

    {:ok, run} =
      Evals.create_run(%{
        workspace_id: workspace.id,
        suite_id: suite.id,
        agent_id: agent.id
      })

    {:ok, _run} = Evals.execute_run(run)

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Failing Thresholded Skill",
        slug: "failing-thresholded-skill",
        description: "Must pass evals.",
        instructions: "Use only after evals pass.",
        evals: %{"suite_id" => suite.slug, "threshold" => 0.8}
      })

    assert {:error, changeset} = Skills.activate_skill(skill)

    assert {"activation requires latest eval pass rate 0.0% to meet 80.0% threshold", _meta} =
             changeset.errors[:evals]

    assert Skills.get_skill!(skill.id).status == "proposed"
    assert [_version] = Skills.list_versions(skill)

    assert {:ok, active} =
             skill.id
             |> Skills.get_skill!()
             |> Skills.activate_skill(%{
               override_activation_gate: true,
               override_actor: "tester",
               override_reason: "Critical incident response"
             })

    assert active.status == "active"

    assert [%{"actor" => "tester", "reason" => "Critical incident response"}] =
             active.provenance["activation_overrides"]
  end

  test "update_skill refines a proposal and appends a version snapshot" do
    workspace = workspace_fixture(%{slug: "skills-version-update"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Draft Skill",
        slug: "draft-skill-version-update",
        description: "Original proposal.",
        instructions: "Original instructions."
      })

    assert {:ok, updated} =
             Skills.update_skill(skill, %{
               name: "Refined Skill",
               slug: "refined-skill-version-update",
               description: "Refined proposal.",
               instructions: "Refined instructions.",
               required_tools: ["knowledge_read"],
               memory_scopes: ["workspace"],
               knowledge_scopes: ["workspace"]
             })

    assert updated.name == "Refined Skill"
    assert updated.required_tools == ["knowledge_read"]

    assert [
             %{version: 2, change_kind: "updated", snapshot: %{"name" => "Refined Skill"}},
             %{version: 1, change_kind: "created", snapshot: %{"name" => "Draft Skill"}}
           ] = Skills.list_versions(skill)
  end

  test "update_skill preserves validation for required tools" do
    workspace = workspace_fixture(%{slug: "skills-version-update-invalid"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Draft Skill",
        slug: "draft-skill-version-update-invalid",
        description: "Original proposal.",
        instructions: "Original instructions."
      })

    assert {:error, changeset} = Skills.update_skill(skill, %{required_tools: ["not_a_tool"]})
    refute changeset.valid?
    assert [version] = Skills.list_versions(skill)
    assert version.change_kind == "created"
  end

  test "propose_from_run creates an idempotent proposed skill from run context" do
    workspace = workspace_fixture(%{slug: "skills-propose-from-run"})
    agent = agent_fixture(workspace, %{slug: "skills-proposal-agent"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Investigate Queue",
        goal: "Find the stuck runtime steps."
      })

    _step =
      run_step_fixture(run, %{
        title: "Read runtime state",
        tool_name: "knowledge_read",
        side_effect_class: "read_only"
      })

    run = HydraAgent.Runtime.get_run_detail!(run.id)

    assert {:ok, skill} = Skills.propose_from_run(run)
    assert skill.status == "proposed"
    assert skill.owner_agent_id == agent.id
    assert skill.source_run_id == run.id
    assert skill.slug == "run-#{run.id}-skill"
    assert skill.required_tools == ["knowledge_read"]
    assert skill.provenance["kind"] == "run_skill_proposal"
    assert skill.instructions =~ "Read runtime state"

    assert {:ok, same_skill} = Skills.propose_from_run(run)
    assert same_skill.id == skill.id
    assert [_version] = Skills.list_versions(skill)
  end

  test "learning loop proposes and auto-activates safe skills from completed runs" do
    workspace = workspace_fixture(%{slug: "skills-learning-auto"})
    agent = agent_fixture(workspace, %{slug: "skills-learning-agent"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Repeatable Research",
        goal: "Run the same research checklist."
      })

    for index <- 0..4 do
      run_step_fixture(run, %{
        index: index,
        title: "Read #{index}",
        tool_name: "knowledge_read",
        side_effect_class: "read_only"
      })
    end

    {:ok, completed} = Runtime.complete_run(run)

    assert {:ok, proposal} =
             Skills.propose_learning_from_run(Runtime.get_run_detail!(completed.id))

    assert proposal.status == "auto_activated"
    assert proposal.kind == "create"

    skill = Skills.get_skill!(proposal.target_skill_id)
    assert skill.status == "active"
    assert skill.required_tools == ["knowledge_read"]

    assert [event] = Skills.list_usage_events(workspace.id, skill_id: skill.id)
    assert event.outcome_status == "success"
    assert event.tool_count == 5
  end

  test "learning loop leaves dangerous skills in draft" do
    workspace = workspace_fixture(%{slug: "skills-learning-dangerous"})
    agent = agent_fixture(workspace, %{slug: "skills-learning-danger-agent"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Patch Files",
        goal: "Patch several files."
      })

    for index <- 0..4 do
      run_step_fixture(run, %{
        index: index,
        title: "Write #{index}",
        tool_name: "file_write",
        side_effect_class: "workspace_write"
      })
    end

    {:ok, completed} = Runtime.complete_run(run)

    assert {:ok, proposal} =
             Skills.propose_learning_from_run(Runtime.get_run_detail!(completed.id))

    assert proposal.status == "draft"
    assert Skills.get_skill!(proposal.target_skill_id).status == "proposed"
  end

  test "skill markdown export and import round-trip through durable skills" do
    workspace = workspace_fixture(%{slug: "skills-markdown-roundtrip"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Markdown Skill",
        slug: "markdown-skill",
        description: "Can be exported.",
        instructions: "Do the thing.",
        required_tools: ["knowledge_read"]
      })

    markdown = Skills.export_markdown(skill)

    assert markdown =~ "# Markdown Skill"

    assert {:ok, imported} =
             Skills.import_markdown(workspace.id, markdown, %{"slug" => "markdown-skill-copy"})

    assert imported.name == "Markdown Skill"
    assert imported.required_tools == ["knowledge_read"]
  end

  test "refinement proposals update skills through governed approval" do
    workspace = workspace_fixture(%{slug: "skills-refinement-proposal"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Draft Review",
        slug: "draft-review-refinement",
        description: "Original description.",
        instructions: "Original instructions.",
        required_tools: ["knowledge_read"],
        provenance: %{"improvement_proposals" => "legacy"}
      })

    assert {:ok, proposal} =
             Skills.create_refinement_proposal(skill, %{
               "description" => "Refined description.",
               "instructions" => "Refined instructions with verification.",
               "metadata" => %{"reason" => "usage review"}
             })

    assert proposal.kind == "refine"
    assert proposal.status == "draft"

    assert {:ok, %{skill: refined}} =
             Skills.approve_improvement_proposal(proposal, %{"actor" => "tester"})

    assert refined.description == "Refined description."
    assert refined.instructions == "Refined instructions with verification."
    assert refined.provenance["improvement_proposals"] == [proposal.id]

    assert [
             %{version: 2, change_kind: "updated"},
             %{version: 1, change_kind: "created"}
           ] = Skills.list_versions(skill)
  end

  test "prune proposals archive skills only after approval" do
    workspace = workspace_fixture(%{slug: "skills-prune-proposal"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Old Procedure",
        slug: "old-procedure-prune",
        description: "No longer useful.",
        instructions: "Do the old thing.",
        required_tools: ["knowledge_read"]
      })

    assert {:ok, proposal} =
             Skills.create_prune_proposal(skill, %{"metadata" => %{"reason" => "superseded"}})

    assert proposal.kind == "prune"
    assert proposal.status == "draft"
    assert Skills.get_skill!(skill.id).status == "proposed"

    assert {:ok, %{skill: archived}} = Skills.approve_improvement_proposal(proposal)
    assert archived.status == "archived"
  end

  test "generated skill eval suites are idempotent and attach activation metadata" do
    workspace = workspace_fixture(%{slug: "skills-generated-evals"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Evidence Review",
        slug: "evidence-review-generated-evals",
        description: "Review evidence before acting.",
        instructions: "Check provenance and summarize risk.",
        required_tools: ["knowledge_read"]
      })

    assert {:ok, %{skill: updated, suite: suite}} = Skills.generate_eval_suite_for_skill(skill)
    assert updated.evals["suite_id"] == suite.slug
    assert updated.evals["threshold"] == 0.85
    assert length(suite.cases) == 3

    assert {:ok, %{suite: same_suite}} =
             skill.id |> Skills.get_skill!() |> Skills.generate_eval_suite_for_skill()

    assert same_suite.id == suite.id
    assert length(same_suite.cases) == 3
  end

  test "standard skill pack seeding is idempotent" do
    workspace = workspace_fixture(%{slug: "skills-standard-pack"})

    assert {:ok, first} = Skills.seed_standard_skill_pack(workspace.id)
    assert length(first) == 5
    assert Enum.any?(first, &(&1.slug == "run-failure-triage"))

    assert {:ok, second} = Skills.seed_standard_skill_pack(workspace.id)
    assert length(second) == 5
    assert length(Skills.list_skills(workspace.id)) == 5
  end

  test "learning worker includes short recovery runs" do
    workspace = workspace_fixture(%{slug: "skills-learning-worker-recovery"})
    agent = agent_fixture(workspace, %{slug: "skills-learning-worker-agent"})

    run =
      run_fixture(workspace, %{
        supervisor_agent_id: agent.id,
        title: "Recover Blocked Run",
        goal: "Recover a failed tool call."
      })

    run_step_fixture(run, %{
      index: 0,
      title: "Read failing step",
      status: "failed",
      tool_name: "knowledge_read",
      side_effect_class: "read_only",
      error: %{"reason" => "timeout"}
    })

    {:ok, failed} = Runtime.fail_run(run)

    assert [%Skills.ImprovementProposal{source_run_id: source_run_id}] =
             LearningWorker.learn_due(%{minimum_tool_count: 5})

    assert source_run_id == failed.id
  end

  test "learning worker scans eligible conversations automatically" do
    workspace = workspace_fixture(%{slug: "skills-worker-conversations"})
    agent = agent_fixture(workspace, %{slug: "skills-worker-conversation-agent"})

    {:ok, conversation} =
      Runtime.create_conversation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        title: "Worker conversation",
        channel: "api"
      })

    for {role, content} <- [
          {"user", "Research this incident"},
          {"assistant", "I will inspect the timeline"},
          {"user", "What should we do next?"},
          {"assistant", "Verify the fix and summarize the risk"}
        ] do
      {:ok, _turn} = Runtime.append_turn(conversation, %{role: role, content: content})
    end

    assert [%Skills.ImprovementProposal{source_conversation_id: source_conversation_id}] =
             LearningWorker.learn_due(%{minimum_tool_count: 5, minimum_turn_count: 4})

    assert source_conversation_id == conversation.id
  end

  test "learning loop proposes skills from arbitrary conversations" do
    workspace = workspace_fixture(%{slug: "skills-conversation-learning"})
    agent = agent_fixture(workspace, %{slug: "skills-conversation-agent"})

    {:ok, conversation} =
      Runtime.create_conversation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        title: "Triage release notes",
        channel: "telegram"
      })

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{role: "user", content: "Summarize the release"})

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{role: "assistant", content: "I will inspect sources"})

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{
        role: "tool",
        kind: "tool_call",
        content: "read notes",
        metadata: %{"tool_name" => "knowledge_read"}
      })

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{
        role: "assistant",
        content: "Final summary with risks and next steps"
      })

    conversation = Runtime.get_conversation!(conversation.id)

    assert {:ok, proposal} =
             Skills.propose_learning_from_conversation(conversation, confidence: 0.9)

    assert proposal.source_conversation_id == conversation.id
    assert proposal.status == "auto_activated"

    skill = Skills.get_skill!(proposal.target_skill_id)
    assert skill.status == "active"
    assert skill.required_tools == ["knowledge_read"]
    assert skill.instructions =~ "Transcript evidence"

    assert [%{conversation_id: conversation_id}] =
             Skills.list_usage_events(workspace.id, skill_id: skill.id)

    assert conversation_id == conversation.id
  end

  test "learning loop proposes skills from shared rooms" do
    workspace = workspace_fixture(%{slug: "skills-room-learning"})
    coordinator = agent_fixture(workspace, %{slug: "skills-room-coordinator"})

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        coordinator_agent_id: coordinator.id,
        title: "Release room",
        slug: "release-room"
      })

    for {author_type, content} <- [
          {"user", "Please compare the release blockers"},
          {"agent", "I will inspect incidents"},
          {"agent", "The highest risk is migration ordering"},
          {"system", "Room summary completed"}
        ] do
      {:ok, _message} =
        %Message{}
        |> Message.changeset(%{
          workspace_id: workspace.id,
          room_id: room.id,
          agent_id: if(author_type == "agent", do: coordinator.id),
          author_type: author_type,
          source_channel: "web",
          content: content,
          metadata: %{"tool_name" => "knowledge_read"}
        })
        |> Repo.insert()
    end

    assert {:ok, proposal} = Skills.propose_learning_from_room(room, confidence: 0.9)
    assert proposal.source_room_id == room.id

    skill = Skills.get_skill!(proposal.target_skill_id)
    assert skill.instructions =~ "group-chat coordination pattern"
    assert skill.required_tools == ["knowledge_read"]
  end

  test "evolve_due auto-activates safe room learning and records the room event" do
    workspace = workspace_fixture(%{slug: "skills-auto-evolve-room"})
    coordinator = agent_fixture(workspace, %{slug: "skills-auto-evolve-coordinator"})

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        coordinator_agent_id: coordinator.id,
        title: "Research Room",
        slug: "research-room"
      })

    for {author_type, content} <- [
          {"user", "Compare these research sources"},
          {"agent", "I will inspect source notes"},
          {"agent", "The strongest source is the primary paper"},
          {"system", "Research comparison completed"},
          {"user", "Turn that into a reusable method"},
          {"agent", "Reusable method captured with source checks"}
        ] do
      {:ok, _message} =
        %Message{}
        |> Message.changeset(%{
          workspace_id: workspace.id,
          room_id: room.id,
          agent_id: if(author_type == "agent", do: coordinator.id),
          author_type: author_type,
          source_channel: "telegram",
          content: content,
          metadata: %{"tool_name" => "knowledge_read"}
        })
        |> Repo.insert()
    end

    assert {:ok, summary} = Skills.evolve_due(workspace.id, minimum_message_count: 4)
    assert summary.auto_activated == 1
    assert summary.drafted == 0

    room = Rooms.get_room!(room.id)
    messages = Rooms.list_messages(room, limit: 20)
    assert Enum.any?(messages, &(&1.content =~ "Hydra auto-activated"))
  end

  test "evolve_due drafts unsafe room learning instead of auto-activating" do
    workspace = workspace_fixture(%{slug: "skills-auto-evolve-unsafe"})
    coordinator = agent_fixture(workspace, %{slug: "skills-auto-evolve-unsafe-agent"})

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        coordinator_agent_id: coordinator.id,
        title: "Delivery Room",
        slug: "delivery-room"
      })

    for content <- [
          "Draft and send a message",
          "I will prepare the delivery",
          "Message is queued",
          "Delivery complete"
        ] do
      {:ok, _message} =
        %Message{}
        |> Message.changeset(%{
          workspace_id: workspace.id,
          room_id: room.id,
          agent_id: coordinator.id,
          author_type: "agent",
          source_channel: "telegram",
          content: content,
          metadata: %{"tool_name" => "file_write"}
        })
        |> Repo.insert()
    end

    assert {:ok, summary} = Skills.evolve_due(workspace.id, minimum_message_count: 4)
    assert summary.auto_activated == 0
    assert summary.blocked == 1

    [result] = summary.results
    assert result["policy_decision"] == "drafted_for_review"
    assert "safe_skill" in result["blocked_reasons"]
  end

  test "restores skill from a previous version" do
    workspace = workspace_fixture(%{slug: "skills-version-restore"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Restore Skill",
        slug: "restore-skill",
        description: "Original description",
        instructions: "Original instructions",
        required_tools: ["knowledge_read"]
      })

    assert {:ok, changed} =
             Skills.update_skill(skill, %{
               description: "Changed description",
               instructions: "Changed instructions"
             })

    assert {:ok, restored} = Skills.restore_skill_version(changed, 1, %{"actor" => "test"})
    assert restored.description == "Original description"
    assert restored.instructions == "Original instructions"
    assert restored.provenance["restored_from_version"] == 1
  end

  test "generated eval suites include real examples from source conversations" do
    workspace = workspace_fixture(%{slug: "skills-real-example-evals"})
    agent = agent_fixture(workspace, %{slug: "skills-real-example-agent"})

    {:ok, conversation} =
      Runtime.create_conversation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        title: "Debug auth",
        channel: "control_plane"
      })

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{role: "user", content: "Find why auth failed"})

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{
        role: "assistant",
        content: "Check token expiry and provider logs"
      })

    {:ok, _turn} = Runtime.append_turn(conversation, %{role: "user", content: "What fixed it?"})

    {:ok, _turn} =
      Runtime.append_turn(conversation, %{
        role: "assistant",
        content: "Rotating the token fixed auth"
      })

    {:ok, proposal} =
      conversation.id
      |> Runtime.get_conversation!()
      |> Skills.propose_learning_from_conversation(confidence: 0.9)

    skill = Skills.get_skill!(proposal.target_skill_id)

    assert {:ok, %{skill: updated, suite: suite}} = Skills.generate_eval_suite_for_skill(skill)
    assert updated.evals["source_example_count"] == 2
    assert length(suite.cases) == 5
    assert Enum.any?(suite.cases, &(&1.prompt == "Find why auth failed"))
  end

  test "project-local code skills create Hermes-compatible directories" do
    root = Path.join(System.tmp_dir!(), "hydra-code-skill-#{System.unique_integer([:positive])}")

    workspace =
      workspace_fixture(%{slug: "skills-code-skill", settings: %{"project_root" => root}})

    assert {:ok, skill} =
             Skills.create_project_code_skill(workspace.id, %{
               name: "Local Script Skill",
               slug: "local-script-skill",
               description: "Run a local helper script.",
               instructions: "Inspect scripts/run.sh before using it.",
               files: %{"scripts/run.sh" => "#!/usr/bin/env bash\necho ok\n"}
             })

    skill_dir = Path.join([root, ".hydra", "skills", "local-script-skill"])
    assert File.regular?(Path.join(skill_dir, "SKILL.md"))
    assert File.regular?(Path.join(skill_dir, "scripts/run.sh"))
    assert skill.provenance["kind"] == "project_code_skill"
    assert skill.required_tools == ["project_skill_run"]
  end

  test "imports Hermes-style skill directories with YAML frontmatter" do
    root =
      Path.join(System.tmp_dir!(), "hydra-hermes-import-#{System.unique_integer([:positive])}")

    skill_dir = Path.join(root, "github-code-review")
    File.mkdir_p!(Path.join(skill_dir, "references"))

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: github-code-review
    description: Review GitHub pull requests with evidence.
    required_tools: [knowledge_read]
    ---

    # GitHub Code Review

    Inspect the diff, identify risks, and summarize findings.
    """)

    File.write!(Path.join(skill_dir, "references/checklist.md"), "Check tests\n")

    workspace = workspace_fixture(%{slug: "skills-hermes-import"})

    assert {:ok, skill} = Skills.import_skill_directory(workspace.id, skill_dir)
    assert skill.slug == "github-code-review"
    assert skill.description == "Review GitHub pull requests with evidence."
    assert skill.provenance["kind"] == "skill_directory_import"
    assert [%{"path" => "references/checklist.md"}] = skill.provenance["supporting_files"]
  end

  test "skill hub scans and approves skill imports" do
    root = Path.join(System.tmp_dir!(), "hydra-skill-hub-#{System.unique_integer([:positive])}")
    skill_dir = Path.join(root, "briefing-skill")
    File.mkdir_p!(Path.join(skill_dir, "scripts"))

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: Skill Hub Import
    required_tools: [knowledge_read]
    ---

    # Skill Hub Import

    Use gathered context to brief the operator.
    """)

    File.write!(Path.join(skill_dir, "scripts/run.sh"), "echo ok\n")

    workspace = workspace_fixture(%{slug: "skills-hub-import"})

    assert {:ok, skill_import} =
             Skills.scan_skill_import(workspace.id, %{
               "path" => skill_dir,
               "source_type" => "local_path"
             })

    assert skill_import.status == "scanned"
    assert skill_import.skill_attrs["slug"] == "skill-hub-import"
    assert Enum.any?(skill_import.file_manifest, &(&1["path"] == "scripts/run.sh"))
    assert Enum.any?(skill_import.warnings, &(&1["code"] == "executable_file"))

    assert {:ok, %{skill: skill, skill_import: installed}} =
             Skills.approve_skill_import(skill_import, %{"approved_by" => "tester"})

    assert skill.slug == "skill-hub-import"
    assert installed.status == "installed"
    assert installed.installed_skill_id == skill.id
  end

  test "skill hub scans compatible AGENTS instruction directories" do
    root =
      Path.join(System.tmp_dir!(), "hydra-agents-skill-hub-#{System.unique_integer([:positive])}")

    skill_dir = Path.join(root, "research-pack")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "AGENTS.md"), """
    # Research Pack

    Use workspace notes and cited sources to prepare a careful research brief.
    Ask for approval before writing to external systems.
    """)

    workspace = workspace_fixture(%{slug: "skills-hub-agents-import"})

    assert {:ok, skill_import} =
             Skills.scan_skill_import(workspace.id, %{
               "path" => skill_dir,
               "source_type" => "local_path"
             })

    assert skill_import.status == "scanned"
    assert skill_import.skill_attrs["name"] == "Research Pack"
    assert skill_import.skill_attrs["slug"] == "research-pack"
    assert skill_import.skill_attrs["trigger_conditions"]["format"] == "agents_md"
    assert skill_import.scan_result["format"] == "agents_md_directory"
    assert skill_import.scan_result["instruction_file"] == "AGENTS.md"
    assert Enum.any?(skill_import.warnings, &(&1["code"] == "compat_instruction_file"))

    assert {:ok, %{skill: skill}} = Skills.approve_skill_import(skill_import)
    assert skill.instructions =~ "careful research brief"
  end

  test "skill hub rejects non-github repo urls before cloning" do
    workspace = workspace_fixture(%{slug: "skills-hub-github-url-safety"})

    assert {:error, %{"reason" => "unsupported_github_repo_url"}} =
             Skills.scan_skill_import(workspace.id, %{
               "source_type" => "github",
               "repo_url" => "https://example.com/not-a-github-repo.git"
             })
  end

  test "safe skill experiments select winning variants and draft refinements" do
    workspace = workspace_fixture(%{slug: "skills-experiment-winner"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Evidence Summary",
        slug: "evidence-summary-experiment",
        description: "Summarize evidence.",
        instructions: "Summarize the facts.",
        required_tools: ["knowledge_read"]
      })

    assert {:ok, experiment} =
             Skills.run_skill_experiment(skill, %{
               examples: [
                 %{
                   prompt: "Summarize and verify the evidence",
                   expected: %{"contains" => ["verify"]}
                 }
               ],
               variants: [
                 %{
                   candidate: "verify_variant",
                   instructions: "Summarize the facts and verify every claim against evidence."
                 }
               ]
             })

    assert experiment.status == "completed"
    assert experiment.winner_snapshot["experiment_candidate"] == "verify_variant"
    assert experiment.selected_proposal_id

    proposal = Skills.get_improvement_proposal!(experiment.selected_proposal_id)
    assert proposal.kind == "refine"
    assert proposal.metadata["experiment_id"] == experiment.id
  end

  test "safe skill experiments reject dangerous tool variants" do
    workspace = workspace_fixture(%{slug: "skills-experiment-unsafe"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Danger Variant",
        slug: "danger-variant",
        description: "Should stay gated.",
        instructions: "Do work.",
        required_tools: ["knowledge_read"]
      })

    assert {:error, %{"reason" => "unsafe_experiment_candidate"}} =
             Skills.run_skill_experiment(skill, %{
               variants: [%{candidate: "write_variant", required_tools: ["file_write"]}]
             })
  end
end
