defmodule HydraAgentWeb.SkillRegistryLiveTest do
  use HydraAgentWeb.ConnCase

  import HydraAgent.RuntimeFixtures
  import Phoenix.LiveViewTest

  alias HydraAgent.{Evals, Runtime, Skills, Usage}

  test "renders empty skills registry", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control/skills")

    assert html =~ "Skill Evolution"
    assert html =~ "No workspaces yet."
  end

  test "renders workspace skills with owners, tools, evals, and nav", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skills-registry"})
    agent = agent_fixture(workspace, %{name: "Runtime Steward", slug: "runtime-steward"})
    run = run_fixture(workspace, %{title: "Extract durable review skill"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        source_run_id: run.id,
        name: "Runtime Triage",
        slug: "runtime-triage",
        description: "Inspect stuck runs and approval queues.",
        instructions: "Check worker state, approvals, and recent safety events.",
        required_tools: ["knowledge_read"],
        memory_scopes: ["workspace"],
        knowledge_scopes: ["workspace"],
        evals: %{"suite_id" => "runtime_triage_eval", "threshold" => 0.85},
        provenance: %{"kind" => "run_extract"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills?workspace_id=#{workspace.id}")

    assert has_element?(view, "#skills-registry")
    assert has_element?(view, "#control-shell-nav")
    assert has_element?(view, "#skill-card-#{skill.id}")

    html = render(view)
    assert html =~ "Runtime Triage"
    assert html =~ "proposed / Runtime Steward"
    assert html =~ "knowledge_read"
    assert html =~ "runtime_triage_eval / 0.85"
    assert html =~ "Skill Evolution"
  end

  test "runs safe skill evolution from the registry", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skills-registry-evolution"})
    agent = agent_fixture(workspace, %{name: "Research Agent", slug: "registry-evolution-agent"})

    {:ok, conversation} =
      Runtime.create_conversation(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        title: "Registry Evolution",
        channel: "telegram"
      })

    for {role, content, metadata} <- [
          {"user", "Summarize these sources", %{}},
          {"assistant", "I will read the approved source notes", %{}},
          {"tool", "read notes", %{"tool_name" => "knowledge_read"}},
          {"assistant", "Summary includes source caveats", %{}},
          {"user", "Reuse this pattern", %{}},
          {"assistant", "Reusable source-summary pattern captured", %{}}
        ] do
      {:ok, _turn} =
        Runtime.append_turn(conversation, %{
          role: role,
          content: content,
          metadata: metadata
        })
    end

    {:ok, view, _html} = live(conn, ~p"/control/skills?workspace_id=#{workspace.id}")

    html =
      view
      |> element("#skills-run-evolution")
      |> render_click()

    assert html =~ "Skill evolution checked"
    assert html =~ "skill-evolution-summary"
    assert html =~ "Auto-activated"
  end

  test "renders cross-skill eval and override analytics", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skills-registry-analytics"})

    agent =
      agent_fixture(workspace, %{
        name: "Quality Agent",
        slug: "quality-agent",
        model_route: %{"default_provider" => "mock"}
      })

    {:ok, _provider} =
      Runtime.create_provider(%{
        workspace_id: workspace.id,
        name: "mock",
        kind: "mock",
        model: "mock-1"
      })

    {:ok, passing_suite} =
      Evals.create_suite(%{
        workspace_id: workspace.id,
        name: "Passing Eval",
        slug: "passing-eval"
      })

    {:ok, _passing_case} =
      Evals.create_case(passing_suite, %{
        name: "Echoes mock",
        slug: "echoes-mock-registry",
        prompt: "hello",
        expected: %{"contains" => ["mock"]}
      })

    {:ok, passing_run} =
      Evals.create_run(%{
        workspace_id: workspace.id,
        suite_id: passing_suite.id,
        agent_id: agent.id
      })

    {:ok, _passing_run} = Evals.execute_run(passing_run)

    {:ok, failing_suite} =
      Evals.create_suite(%{
        workspace_id: workspace.id,
        name: "Failing Eval",
        slug: "failing-eval"
      })

    {:ok, _failing_case} =
      Evals.create_case(failing_suite, %{
        name: "Requires refusal",
        slug: "requires-refusal-registry",
        prompt: "hello",
        expected: %{"contains" => ["cannot comply"]}
      })

    {:ok, failing_run} =
      Evals.create_run(%{
        workspace_id: workspace.id,
        suite_id: failing_suite.id,
        agent_id: agent.id
      })

    {:ok, _failing_run} = Evals.execute_run(failing_run)

    {:ok, _passing_skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Passing Skill",
        slug: "passing-skill-registry",
        description: "Passes threshold.",
        instructions: "Use after eval passes.",
        evals: %{"suite_id" => passing_suite.slug, "threshold" => 0.9}
      })

    {:ok, _failing_skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Failing Skill",
        slug: "failing-skill-registry",
        description: "Fails threshold.",
        instructions: "Needs work.",
        evals: %{"suite_id" => failing_suite.slug, "threshold" => 0.8},
        provenance: %{
          "activation_overrides" => [
            %{"actor" => "operator", "reason" => "supervised rollout"}
          ]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills?workspace_id=#{workspace.id}")

    assert has_element?(view, "#skills-registry-analytics")

    html = render(view)
    assert html =~ "Thresholded"
    assert html =~ "Passing"
    assert html =~ "Blocked"
    assert html =~ "Overrides"
    assert html =~ "latest pass 100.0% / passing / overrides 0"
    assert html =~ "latest pass 0.0% / below threshold / overrides 1"
  end

  test "filters skills by lifecycle status", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skills-filter"})

    {:ok, proposed} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Proposed Skill",
        slug: "proposed-skill",
        description: "Not tested yet.",
        instructions: "Wait for validation."
      })

    {:ok, active} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Active Skill",
        slug: "active-skill",
        description: "Ready to use.",
        status: "active",
        instructions: "Use when needed."
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills?workspace_id=#{workspace.id}")

    assert has_element?(view, "#skill-card-#{proposed.id}")
    assert has_element?(view, "#skill-card-#{active.id}")

    view
    |> form("#skills-filter-form", %{status: "active"})
    |> render_change()

    assert_patch(view, ~p"/control/skills?workspace_id=#{workspace.id}&status=active")
    refute has_element?(view, "#skill-card-#{proposed.id}")
    assert has_element?(view, "#skill-card-#{active.id}")
  end

  test "registry lifecycle actions update skill state", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skills-actions"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Review Skill",
        slug: "review-skill",
        description: "Review generated memory proposals.",
        instructions: "Validate provenance first."
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills?workspace_id=#{workspace.id}")

    view |> element("#skill-test-#{skill.id}") |> render_click()
    assert Skills.get_skill!(skill.id).status == "testing"

    view |> element("#skill-activate-#{skill.id}") |> render_click()
    activated = Skills.get_skill!(skill.id)
    assert activated.status == "active"
    assert activated.activated_at

    view |> element("#skill-deprecate-#{skill.id}") |> render_click()
    deprecated = Skills.get_skill!(skill.id)
    assert deprecated.status == "deprecated"
    assert deprecated.deprecated_at

    view |> element("#skill-archive-#{skill.id}") |> render_click()
    assert Skills.get_skill!(skill.id).status == "archived"
  end

  test "registry skill learning actions seed, evaluate, refine, and prune", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skills-learning-actions"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Learning Action Skill",
        slug: "learning-action-skill",
        description: "Needs productized controls.",
        instructions: "Check evidence.",
        required_tools: ["knowledge_read"]
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills?workspace_id=#{workspace.id}")

    view |> element("#skill-generate-eval-#{skill.id}") |> render_click()
    updated = Skills.get_skill!(skill.id)
    assert updated.evals["suite_id"] == "skill-learning-action-skill-eval"

    view |> element("#skill-experiment-#{skill.id}") |> render_click()
    assert [%{status: "completed"}] = Skills.list_experiments(workspace.id, skill_id: skill.id)

    view |> element("#skill-refine-#{skill.id}") |> render_click()

    assert Enum.any?(
             Skills.list_improvement_proposals(workspace.id, kind: "refine"),
             &(&1.status == "draft")
           )

    view |> element("#skill-prune-#{skill.id}") |> render_click()

    assert [%{kind: "prune", status: "draft"}] =
             Skills.list_improvement_proposals(workspace.id, kind: "prune")

    view |> element("#skills-seed-standard-pack") |> render_click()
    assert Enum.any?(Skills.list_skills(workspace.id), &(&1.slug == "run-failure-triage"))
  end

  test "renders skill detail and detail lifecycle controls", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skill-detail"})
    agent = agent_fixture(workspace, %{name: "Memory Curator", slug: "memory-curator"})
    run = run_fixture(workspace, %{title: "Learn memory review"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        source_run_id: run.id,
        name: "Memory Review",
        slug: "memory-review",
        description: "Review durable memory proposals.",
        instructions: "Check provenance, confidence, and duplicate risk.",
        trigger_conditions: %{"when" => "memory proposal pending"},
        required_tools: ["knowledge_read", "knowledge_write"],
        memory_scopes: ["workspace"],
        knowledge_scopes: ["workspace"],
        evals: %{"suite_id" => "memory_review_eval"},
        provenance: %{"kind" => "operator_seed"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")

    assert has_element?(view, "#skill-detail")
    assert has_element?(view, "#skill-detail-instructions")
    assert has_element?(view, "#skill-detail-permissions")
    assert has_element?(view, "#skill-detail-triggers")
    assert has_element?(view, "#skill-detail-evals")
    assert has_element?(view, "#skill-detail-provenance")
    assert has_element?(view, "#skill-detail-version-history")
    assert has_element?(view, "#skill-detail-version-1")

    html = render(view)
    assert html =~ "Memory Curator"
    assert html =~ "Learn memory review"
    assert html =~ "knowledge_read, knowledge_write"
    assert html =~ "memory workspace"
    assert html =~ "memory_review_eval"
    assert html =~ "operator_seed"
    assert html =~ "Version 1 / created"

    view |> element("#skill-detail-activate") |> render_click()
    assert Skills.get_skill!(skill.id).status == "active"
    assert render(view) =~ "Version 2 / active"

    view
    |> element("#skill-detail-version-1 button", "Restore")
    |> render_click()

    restored = Skills.get_skill!(skill.id)
    assert restored.status == "proposed"
    assert restored.provenance["restored_from_version"] == 1
    assert render(view) =~ "Version 3 / restored"
  end

  test "skill detail edits proposed skill drafts before activation", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skill-detail-edit"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Draft Skill",
        slug: "draft-skill-detail-edit",
        description: "Original description.",
        instructions: "Original instructions."
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")

    view |> element("#skill-detail-edit") |> render_click()
    assert has_element?(view, "#skill-detail-form")

    view
    |> form("#skill-detail-form", %{
      skill: %{
        name: "Refined Skill",
        slug: "refined-skill-detail-edit",
        description: "Refined description.",
        instructions: "Refined instructions.",
        required_tools: "knowledge_read, knowledge_write",
        memory_scopes: "workspace",
        knowledge_scopes: "workspace, project",
        trigger_conditions: ~s({"when":"memory proposal pending"}),
        evals: ~s({"suite_id":"memory-review","threshold":0.9}),
        provenance: ~s({"kind":"operator_review"})
      }
    })
    |> render_submit()

    updated = Skills.get_skill!(skill.id)
    assert updated.name == "Refined Skill"
    assert updated.slug == "refined-skill-detail-edit"
    assert updated.description == "Refined description."
    assert updated.instructions == "Refined instructions."
    assert updated.required_tools == ["knowledge_read", "knowledge_write"]
    assert updated.memory_scopes == ["workspace"]
    assert updated.knowledge_scopes == ["workspace", "project"]
    assert updated.trigger_conditions == %{"when" => "memory proposal pending"}
    assert updated.evals == %{"suite_id" => "memory-review", "threshold" => 0.9}
    assert updated.provenance == %{"kind" => "operator_review"}

    html = render(view)
    assert html =~ "Refined Skill"
    assert html =~ "Refined instructions."
    assert html =~ "knowledge_read, knowledge_write"
    assert html =~ "Version 2 / updated"
    assert html =~ "required tools"
    assert html =~ "trigger conditions"
    assert html =~ "provenance"

    refute has_element?(view, "#skill-detail-form")
  end

  test "skill detail edit form shows validation errors", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skill-detail-edit-errors"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Draft Skill",
        slug: "draft-skill-detail-edit-errors",
        description: "Original description.",
        instructions: "Original instructions."
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")

    view |> element("#skill-detail-edit") |> render_click()

    html =
      view
      |> form("#skill-detail-form", %{
        skill: %{
          name: "",
          slug: "broken slug",
          description: "",
          instructions: "",
          required_tools: "unknown_tool",
          memory_scopes: "",
          knowledge_scopes: ""
        }
      })
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert html =~ "has invalid format"
    assert html =~ "contains unknown registered tools"
    assert Skills.get_skill!(skill.id).name == "Draft Skill"
    assert [_version] = Skills.list_versions(skill)
  end

  test "skill detail edit form validates advanced JSON metadata", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skill-detail-json-errors"})

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        name: "Draft Skill",
        slug: "draft-skill-detail-json-errors",
        description: "Original description.",
        instructions: "Original instructions.",
        evals: %{"suite_id" => "old-suite"}
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")

    view |> element("#skill-detail-edit") |> render_click()

    html =
      view
      |> form("#skill-detail-form", %{
        skill: %{
          name: "Draft Skill",
          slug: "draft-skill-detail-json-errors",
          description: "Original description.",
          instructions: "Original instructions.",
          required_tools: "",
          memory_scopes: "",
          knowledge_scopes: "",
          trigger_conditions: ~s({"when":"manual"}),
          evals: "[not a map]",
          provenance: ~s({"kind":"operator_seed"})
        }
      })
      |> render_submit()

    assert html =~ "must be valid JSON"
    assert Skills.get_skill!(skill.id).evals == %{"suite_id" => "old-suite"}
    assert [_version] = Skills.list_versions(skill)
  end

  test "skill detail shows owner-agent usage and attached eval reports", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skill-usage-evals"})

    agent =
      agent_fixture(workspace, %{
        name: "Eval Curator",
        slug: "eval-curator",
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
        name: "Memory Review Eval",
        slug: "memory-review-eval"
      })

    {:ok, _case} =
      Evals.create_case(suite, %{
        name: "Echoes mock response",
        slug: "echoes-mock-response",
        prompt: "summarize review queue",
        expected: %{"contains" => ["mock"]}
      })

    {:ok, run} =
      Evals.create_run(%{
        workspace_id: workspace.id,
        suite_id: suite.id,
        agent_id: agent.id
      })

    {:ok, _run} = Evals.execute_run(run)

    {:ok, _chat_usage} =
      Usage.create_record(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        provider: "mock",
        model: "mock-1",
        category: "chat",
        status: "ok",
        input_tokens: 3,
        output_tokens: 7,
        total_tokens: 10
      })

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Memory Review",
        slug: "memory-review-usage-eval",
        description: "Review durable memory proposals.",
        instructions: "Check provenance, confidence, and duplicate risk.",
        evals: %{"suite_id" => suite.slug, "threshold" => 0.9}
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")

    assert has_element?(view, "#skill-detail-eval-reports")
    assert has_element?(view, "#skill-detail-eval-report-#{run.id}")

    html = render(view)
    assert html =~ "Activation Readiness"
    assert html =~ "ready"
    assert html =~ "10"
    assert html =~ "2 owner-agent records"
    assert html =~ "1"
    assert html =~ "memory-review-eval"
    assert html =~ "100.0%"
    assert html =~ "100.0% pass rate meets 90.0% threshold"
    assert html =~ "passed 1 / failed 0 / errored 0"

    view |> element("#skill-detail-activate") |> render_click()
    assert Skills.get_skill!(skill.id).status == "active"
  end

  test "skill detail compares recent eval reports", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skill-eval-comparison"})

    agent =
      agent_fixture(workspace, %{
        name: "Eval Comparator",
        slug: "eval-comparator",
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
        name: "Comparison Eval",
        slug: "comparison-eval"
      })

    {:ok, _passing_case} =
      Evals.create_case(suite, %{
        name: "Echoes mock response",
        slug: "echoes-mock-response-comparison",
        prompt: "summarize review queue",
        expected: %{"contains" => ["mock"]}
      })

    {:ok, previous_run} =
      Evals.create_run(%{
        workspace_id: workspace.id,
        suite_id: suite.id,
        agent_id: agent.id
      })

    {:ok, _previous_run} = Evals.execute_run(previous_run)

    {:ok, _failing_case} =
      Evals.create_case(suite, %{
        name: "Requires refusal language",
        slug: "requires-refusal-language-comparison",
        prompt: "summarize review queue",
        expected: %{"contains" => ["cannot comply"]}
      })

    {:ok, latest_run} =
      Evals.create_run(%{
        workspace_id: workspace.id,
        suite_id: suite.id,
        agent_id: agent.id
      })

    {:ok, _latest_run} = Evals.execute_run(latest_run)

    {:ok, skill} =
      Skills.create_skill(%{
        workspace_id: workspace.id,
        owner_agent_id: agent.id,
        name: "Comparable Skill",
        slug: "comparable-skill",
        description: "Compare eval runs.",
        instructions: "Inspect quality trends before activation.",
        evals: %{"suite_id" => suite.slug, "threshold" => 0.5}
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")

    assert has_element?(view, "#skill-detail-eval-comparisons")

    assert has_element?(
             view,
             "#skill-detail-eval-comparison-#{latest_run.id}-#{previous_run.id}"
           )

    html = render(view)
    assert html =~ "Eval Comparison"
    assert html =~ "Run #{latest_run.id} vs #{previous_run.id}"
    assert html =~ "pass rate -50.0%"
    assert html =~ "average -50.0%"
    assert html =~ "failed +1"
    assert html =~ "50.0% pass rate meets 50.0% threshold"
  end

  test "skill detail shows eval failure drill-downs and readiness warnings", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Ops", slug: "ops-skill-eval-failure"})

    agent =
      agent_fixture(workspace, %{
        name: "Eval Curator",
        slug: "eval-curator-failure",
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
        name: "Memory Review Eval",
        slug: "memory-review-failure-eval"
      })

    {:ok, _case} =
      Evals.create_case(suite, %{
        name: "Requires refusal language",
        slug: "requires-refusal-language",
        prompt: "summarize review queue",
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
        name: "Memory Review",
        slug: "memory-review-eval-failure",
        description: "Review durable memory proposals.",
        instructions: "Check provenance, confidence, and duplicate risk.",
        evals: %{"suite_id" => suite.slug, "threshold" => 0.8}
      })

    {:ok, view, _html} = live(conn, ~p"/control/skills/#{skill.id}?workspace_id=#{workspace.id}")

    assert has_element?(view, "#skill-detail-readiness")
    assert has_element?(view, "#skill-detail-eval-report-#{run.id}-failures")

    html = render(view)
    assert html =~ "needs review"
    assert html =~ "0.0% pass rate is below 80.0% threshold"
    assert html =~ "requires-refusal-language / failed"
    assert html =~ "passed 0 / failed 1 / errored 0"
    assert html =~ "Override Activate"
    assert has_element?(view, "#skill-detail-override-activation-form")

    view |> element("#skill-detail-activate") |> render_click()
    assert Skills.get_skill!(skill.id).status == "proposed"

    assert render(view) =~
             "activation requires latest eval pass rate 0.0% to meet 80.0% threshold"

    view
    |> form("#skill-detail-override-activation-form", %{
      override: %{override_reason: "Ship with human supervision"}
    })
    |> render_submit()

    overridden = Skills.get_skill!(skill.id)
    assert overridden.status == "active"

    assert [
             %{
               "actor" => "skill_detail",
               "reason" => "Ship with human supervision"
             }
           ] = overridden.provenance["activation_overrides"]

    html = render(view)
    assert html =~ "Skill activated with operator override"
    assert html =~ "Activation Overrides"
    assert html =~ "Ship with human supervision"
    assert html =~ "actor skill_detail"
  end
end
