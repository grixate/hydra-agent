defmodule HydraAgent.Skills do
  @moduledoc """
  Durable skill library.

  Skills are proposed, tested, activated, deprecated, and audited as workspace
  data instead of being hidden prompt text.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.Multi
  alias HydraAgent.{Evals, Rooms, Runtime}
  alias HydraAgent.Evals.{Case, Suite}
  alias HydraAgent.Repo
  alias HydraAgent.Rooms.Room
  alias HydraAgent.Runtime.{Conversation, Run}

  alias HydraAgent.Skills.{
    Experiment,
    ImprovementProposal,
    Skill,
    SkillImport,
    SkillVersion,
    UsageEvent
  }

  alias HydraAgent.Tools.Registry

  @skill_import_instruction_files ["SKILL.md", "AGENTS.md", "CLAUDE.md", "README.md"]

  @seed_skill_pack [
    %{
      "name" => "Run Failure Triage",
      "slug" => "run-failure-triage",
      "description" =>
        "Inspect failed or blocked runs and produce an operator-ready recovery summary.",
      "instructions" =>
        "Review the run timeline, failed steps, safety events, and checkpoints. Summarize the failure, likely cause, confidence, and the safest next action.",
      "trigger_conditions" => %{"when" => "run failed, blocked, or needs recovery"},
      "required_tools" => ["knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    %{
      "name" => "Repository Change Review",
      "slug" => "repository-change-review",
      "description" =>
        "Review local code changes for regressions, missing tests, and risky behavior.",
      "instructions" =>
        "Inspect changed files, identify behavioral risks first, call out missing tests, and keep recommendations scoped to the requested change.",
      "trigger_conditions" => %{"when" => "operator asks for code review or change audit"},
      "required_tools" => ["file_list", "file_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    %{
      "name" => "Research Synthesis",
      "slug" => "research-synthesis",
      "description" =>
        "Turn gathered notes, repository evidence, or web findings into a concise decision brief.",
      "instructions" =>
        "Collect relevant evidence, separate facts from inference, cite provenance when available, and end with the recommended next move.",
      "trigger_conditions" => %{
        "when" => "operator asks to compare concepts or synthesize research"
      },
      "required_tools" => ["knowledge_search", "knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    %{
      "name" => "Memory Curation",
      "slug" => "memory-curation",
      "description" => "Evaluate memory candidates before promoting them into durable recall.",
      "instructions" =>
        "Check provenance, duplicate risk, sensitivity, and future usefulness. Promote only durable facts or preferences with clear source context.",
      "trigger_conditions" => %{"when" => "new memory proposal needs review"},
      "required_tools" => ["knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    },
    %{
      "name" => "Agent Handoff",
      "slug" => "agent-handoff",
      "description" => "Prepare concise handoffs between agents or across resumed work.",
      "instructions" =>
        "Capture the goal, current state, completed work, blockers, next actions, and verification status without losing operational details.",
      "trigger_conditions" => %{"when" => "work is paused, resumed, delegated, or transferred"},
      "required_tools" => ["knowledge_read"],
      "memory_scopes" => ["workspace"],
      "knowledge_scopes" => ["workspace"]
    }
  ]

  def list_skills(workspace_id, opts \\ []) do
    Skill
    |> where([skill], skill.workspace_id == ^workspace_id)
    |> maybe_filter_status(opt(opts, :status))
    |> order_by([skill], asc: skill.name)
    |> Repo.all()
  end

  def get_skill!(id), do: Repo.get!(Skill, id)

  def list_usage_events(workspace_id, opts \\ []) do
    UsageEvent
    |> where([event], event.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:skill_id, opt(opts, :skill_id))
    |> maybe_filter(:run_id, opt(opts, :run_id))
    |> order_by([event], desc: event.inserted_at)
    |> limit(^opt(opts, :limit, 100))
    |> Repo.all()
  end

  def record_usage_event(attrs) do
    attrs = stringify_keys(attrs)
    %UsageEvent{} |> UsageEvent.changeset(attrs) |> Repo.insert()
  end

  def list_improvement_proposals(workspace_id, opts \\ []) do
    ImprovementProposal
    |> where([proposal], proposal.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:status, opt(opts, :status))
    |> maybe_filter(:kind, opt(opts, :kind))
    |> order_by([proposal], desc: proposal.inserted_at)
    |> preload([:target_skill])
    |> Repo.all()
  end

  def get_improvement_proposal!(id) do
    ImprovementProposal
    |> Repo.get!(id)
    |> Repo.preload([:target_skill])
  end

  def get_skill_by_source_run_id(run_id) do
    Skill
    |> where([skill], skill.source_run_id == ^run_id)
    |> order_by([skill], asc: skill.id)
    |> limit(1)
    |> Repo.one()
  end

  def list_experiments(workspace_id, opts \\ []) do
    Experiment
    |> where([experiment], experiment.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:skill_id, opt(opts, :skill_id))
    |> maybe_filter(:status, opt(opts, :status))
    |> order_by([experiment], desc: experiment.inserted_at)
    |> preload([:skill, :selected_proposal])
    |> Repo.all()
  end

  def get_experiment!(id) do
    Experiment
    |> Repo.get!(id)
    |> Repo.preload([:skill, :selected_proposal])
  end

  def create_skill(attrs) do
    attrs = stringify_keys(attrs)

    Multi.new()
    |> Multi.insert(:skill, %Skill{} |> Skill.changeset(attrs))
    |> Multi.run(:version, fn repo, %{skill: skill} ->
      insert_version(repo, skill, "created")
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{skill: skill}} -> {:ok, skill}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  def create_improvement_proposal(attrs) do
    attrs = stringify_keys(attrs)

    %ImprovementProposal{}
    |> ImprovementProposal.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, proposal} -> maybe_auto_activate_proposal(proposal)
      error -> error
    end
  end

  def create_refinement_proposal(%Skill{} = skill, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    create_improvement_proposal(%{
      workspace_id: skill.workspace_id,
      target_skill_id: skill.id,
      kind: "refine",
      proposed_snapshot: refinement_snapshot(skill, attrs),
      evaluation_report: attrs["evaluation_report"] || manual_proposal_report("refine"),
      confidence: attrs["confidence"] || 0.72,
      metadata:
        Map.merge(
          %{"created_by" => "operator", "source" => "skill_refinement"},
          attrs["metadata"] || %{}
        )
    })
  end

  def create_prune_proposal(%Skill{} = skill, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    create_improvement_proposal(%{
      workspace_id: skill.workspace_id,
      target_skill_id: skill.id,
      kind: "prune",
      proposed_snapshot:
        skill
        |> snapshot()
        |> Map.put("provenance", Map.merge(skill.provenance || %{}, attrs["provenance"] || %{})),
      evaluation_report: attrs["evaluation_report"] || manual_proposal_report("prune"),
      confidence: attrs["confidence"] || 0.65,
      metadata:
        Map.merge(
          %{"created_by" => "operator", "source" => "skill_prune"},
          attrs["metadata"] || %{}
        )
    })
  end

  def generate_eval_suite_for_skill(%Skill{} = skill, attrs \\ %{}) do
    attrs = stringify_keys(attrs)
    slug = attrs["slug"] || "skill-#{skill.slug}-eval"
    examples = eval_generation_examples(skill, attrs)
    cases = generated_eval_cases(skill, examples)

    with {:ok, suite} <-
           upsert_eval_suite(skill.workspace_id, %{
             "workspace_id" => skill.workspace_id,
             "name" => attrs["name"] || "#{skill.name} Eval",
             "slug" => slug,
             "description" =>
               attrs["description"] ||
                 "Generated acceptance checks for the #{skill.name} skill.",
             "metadata" => %{
               "generated_by" => "hydra_skill_learning",
               "skill_id" => skill.id,
               "skill_slug" => skill.slug
             }
           }),
         {:ok, _cases} <- upsert_eval_cases(suite, cases),
         {:ok, skill} <-
           update_skill(skill, %{
             "evals" =>
               Map.merge(skill.evals || %{}, %{
                 "suite_id" => suite.slug,
                 "threshold" => attrs["threshold"] || 0.85,
                 "generated_case_count" => length(cases),
                 "source_example_count" => length(examples),
                 "generated_at" => DateTime.to_iso8601(now())
               })
           }) do
      {:ok, %{skill: skill, suite: Evals.get_suite!(suite.id)}}
    end
  end

  def seed_standard_skill_pack(workspace_id, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    results =
      Enum.map(@seed_skill_pack, fn spec ->
        seed_skill(workspace_id, Map.merge(spec, attrs["defaults"] || %{}))
      end)

    errors = Enum.filter(results, &match?({:error, _error}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, skill} -> skill end)}
    else
      {:error, Enum.map(errors, fn {:error, error} -> error end)}
    end
  end

  def propose_learning_from_conversation(%Conversation{} = conversation, opts \\ []) do
    conversation = Repo.preload(conversation, [:agent, :turns])

    with :ok <- eligible_learning_conversation(conversation, opts),
         {:ok, skill} <- propose_from_conversation(conversation),
         :ok <- record_conversation_usage(conversation, skill) do
      create_improvement_proposal(%{
        workspace_id: conversation.workspace_id,
        target_skill_id: skill.id,
        source_conversation_id: conversation.id,
        kind: "create",
        proposed_snapshot: snapshot(skill),
        evaluation_report:
          opt(opts, :evaluation_report, conversation_learning_report(conversation)),
        confidence: opt(opts, :confidence, conversation_learning_confidence(conversation)),
        metadata: %{
          "created_by" => "conversation_learning_worker",
          "turn_count" => length(conversation.turns || []),
          "trigger" => "conversation_pattern"
        }
      })
    end
  end

  def propose_learning_from_room(%Room{} = room, opts \\ []) do
    room = Rooms.get_room!(room.id)
    messages = Rooms.list_messages(room, limit: opt(opts, :limit, 100))

    with :ok <- eligible_learning_room(room, messages, opts),
         {:ok, skill} <- propose_from_room(room, messages),
         :ok <- record_room_usage(room, messages, skill) do
      create_improvement_proposal(%{
        workspace_id: room.workspace_id,
        target_skill_id: skill.id,
        source_room_id: room.id,
        kind: "create",
        proposed_snapshot: snapshot(skill),
        evaluation_report: opt(opts, :evaluation_report, room_learning_report(messages)),
        confidence: opt(opts, :confidence, room_learning_confidence(messages)),
        metadata: %{
          "created_by" => "room_learning_worker",
          "message_count" => length(messages),
          "trigger" => "room_pattern"
        }
      })
    end
  end

  def propose_from_conversation(%Conversation{} = conversation) do
    conversation = Repo.preload(conversation, [:agent, :turns])

    case Repo.get_by(Skill,
           workspace_id: conversation.workspace_id,
           slug: "conversation-#{conversation.id}-skill"
         ) do
      %Skill{} = skill ->
        {:ok, skill}

      nil ->
        create_skill(%{
          workspace_id: conversation.workspace_id,
          owner_agent_id: conversation.agent_id,
          name: conversation_proposal_name(conversation),
          slug: "conversation-#{conversation.id}-skill",
          description: conversation_proposal_description(conversation),
          instructions: conversation_proposal_instructions(conversation),
          trigger_conditions: %{
            "source" => "conversation_review",
            "conversation_id" => conversation.id,
            "channel" => conversation.channel
          },
          required_tools: conversation_tools(conversation),
          memory_scopes: ["workspace"],
          knowledge_scopes: ["workspace"],
          provenance: %{
            "kind" => "conversation_skill_proposal",
            "source_conversation_id" => conversation.id,
            "source_conversation_title" => conversation.title
          }
        })
    end
  end

  def propose_from_room(%Room{} = room, messages \\ nil) do
    messages = messages || Rooms.list_messages(room, limit: 100)

    case Repo.get_by(Skill, workspace_id: room.workspace_id, slug: "room-#{room.id}-skill") do
      %Skill{} = skill ->
        {:ok, skill}

      nil ->
        create_skill(%{
          workspace_id: room.workspace_id,
          owner_agent_id: room.coordinator_agent_id,
          name: room_proposal_name(room),
          slug: "room-#{room.id}-skill",
          description: room_proposal_description(room),
          instructions: room_proposal_instructions(room, messages),
          trigger_conditions: %{
            "source" => "room_review",
            "room_id" => room.id,
            "room_slug" => room.slug
          },
          required_tools: room_tools(messages),
          memory_scopes: ["workspace"],
          knowledge_scopes: ["workspace"],
          provenance: %{
            "kind" => "room_skill_proposal",
            "source_room_id" => room.id,
            "source_room_title" => room.title
          }
        })
    end
  end

  def create_project_code_skill(workspace_id, attrs) do
    attrs = stringify_keys(attrs)
    slug = slugify(attrs["slug"] || attrs["name"] || "project-code-skill")
    files = attrs["files"] || %{}

    with :ok <- validate_code_skill_slug(slug),
         {:ok, root} <- project_skill_root(workspace_id, attrs),
         {:ok, normalized_files} <- normalize_code_skill_files(files),
         skill_dir <- Path.join(root, slug),
         :ok <- write_code_skill_files(skill_dir, slug, attrs, normalized_files) do
      create_skill(%{
        workspace_id: workspace_id,
        name: attrs["name"] || titleize(slug),
        slug: slug,
        description: attrs["description"] || "Project-local code skill.",
        status: attrs["status"] || "proposed",
        instructions:
          attrs["instructions"] ||
            "Use the project-local files in #{skill_dir} as the implementation reference.",
        trigger_conditions:
          attrs["trigger_conditions"] ||
            %{
              "source" => "project_code_skill",
              "project_path" => skill_dir
            },
        required_tools: attrs["required_tools"] || ["project_skill_run"],
        memory_scopes: attrs["memory_scopes"] || ["workspace"],
        knowledge_scopes: attrs["knowledge_scopes"] || ["workspace"],
        provenance: %{
          "kind" => "project_code_skill",
          "source" => "hydra_project_local",
          "skill_dir" => skill_dir,
          "files" =>
            Enum.map(normalized_files, fn {path, content} ->
              %{"path" => path, "sha256" => sha256(content), "bytes" => byte_size(content)}
            end)
        }
      })
    end
  end

  def import_skill_directory(workspace_id, path, attrs \\ %{}) when is_binary(path) do
    attrs = stringify_keys(attrs)
    skill_path = Path.expand(path)
    skill_md = Path.join(skill_path, "SKILL.md")

    with true <- File.dir?(skill_path) || {:error, %{"reason" => "skill_directory_missing"}},
         true <- File.regular?(skill_md) || {:error, %{"reason" => "skill_markdown_missing"}},
         {:ok, markdown} <- File.read(skill_md) do
      import_markdown(
        workspace_id,
        markdown,
        Map.merge(attrs, %{
          "provenance" => %{
            "kind" => "skill_directory_import",
            "source_path" => skill_path,
            "supporting_files" => supporting_skill_files(skill_path)
          }
        })
      )
    end
  end

  def list_skill_imports(workspace_id, opts \\ []) do
    SkillImport
    |> where([skill_import], skill_import.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:status, opt(opts, :status))
    |> order_by([skill_import], desc: skill_import.inserted_at)
    |> preload([:installed_skill])
    |> Repo.all()
  end

  def get_skill_import!(id) do
    SkillImport
    |> Repo.get!(id)
    |> Repo.preload([:installed_skill])
  end

  def get_skill_import_for_workspace!(workspace_id, id) do
    SkillImport
    |> where([skill_import], skill_import.workspace_id == ^normalize_id(workspace_id))
    |> Repo.get!(normalize_id(id))
    |> Repo.preload([:installed_skill])
  end

  def scan_skill_import(workspace_id, attrs) do
    attrs = stringify_keys(attrs)
    source_type = attrs["source_type"] || infer_import_source_type(attrs)

    try do
      with {:ok, skill_path, source} <- materialize_skill_import_source(source_type, attrs),
           {:ok, scan} <- scan_skill_path(skill_path, attrs) do
        status =
          if Enum.any?(scan.warnings, &(&1["severity"] == "blocker")),
            do: "blocked",
            else: "scanned"

        %SkillImport{}
        |> SkillImport.changeset(%{
          "workspace_id" => workspace_id,
          "source_type" => source_type,
          "source_url" => source["source_url"],
          "source_path" => source["source_path"],
          "source_ref" => source["source_ref"],
          "status" => status,
          "skill_attrs" => scan.skill_attrs,
          "file_manifest" => scan.file_manifest,
          "scan_result" => scan.scan_result,
          "warnings" => scan.warnings,
          "metadata" => %{"scanner" => "hydra_skill_hub_v1"}
        })
        |> Repo.insert()
      end
    after
      cleanup_skill_import_source(Process.get(:hydra_skill_import_tmp_dir))
      Process.delete(:hydra_skill_import_tmp_dir)
    end
  end

  def approve_skill_import(%SkillImport{} = skill_import),
    do: approve_skill_import(skill_import, %{})

  def approve_skill_import(%SkillImport{status: status} = skill_import, attrs)
      when status in ["scanned", "approved"] do
    attrs = stringify_keys(attrs)
    skill_attrs = Map.merge(skill_import.skill_attrs || %{}, attrs["skill"] || %{})

    create_skill(
      Map.merge(skill_attrs, %{
        "workspace_id" => skill_import.workspace_id,
        "provenance" =>
          Map.merge(skill_attrs["provenance"] || %{}, %{
            "kind" => "skill_hub_import",
            "skill_import_id" => skill_import.id,
            "source_type" => skill_import.source_type,
            "source_url" => skill_import.source_url,
            "source_path" => skill_import.source_path,
            "source_ref" => skill_import.source_ref,
            "file_manifest" => skill_import.file_manifest
          })
      })
    )
    |> case do
      {:ok, skill} ->
        skill_import
        |> SkillImport.changeset(%{
          "status" => "installed",
          "installed_skill_id" => skill.id,
          "approved_by" => attrs["approved_by"] || "operator",
          "approved_at" => now()
        })
        |> Repo.update()
        |> case do
          {:ok, skill_import} ->
            {:ok, %{skill_import: Repo.preload(skill_import, [:installed_skill]), skill: skill}}

          error ->
            error
        end

      error ->
        error
    end
  end

  def approve_skill_import(%SkillImport{} = skill_import, _attrs),
    do: {:error, %{"reason" => "skill_import_not_approvable", "status" => skill_import.status}}

  def reject_skill_import(%SkillImport{} = skill_import, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    skill_import
    |> SkillImport.changeset(%{
      "status" => "rejected",
      "approved_by" => attrs["rejected_by"] || attrs["approved_by"] || "operator",
      "approved_at" => now(),
      "metadata" => Map.put(skill_import.metadata || %{}, "rejection_reason", attrs["reason"])
    })
    |> Repo.update()
  end

  def run_skill_experiment(%Skill{} = skill, attrs \\ %{}) do
    attrs = stringify_keys(attrs)
    examples = experiment_examples(skill, attrs)
    candidates = experiment_candidates(skill, attrs)

    with :ok <- validate_safe_experiment(candidates),
         report <- evaluate_candidates(candidates, examples),
         winner <- winner_candidate(report),
         {:ok, experiment} <- create_experiment(skill, attrs, candidates, report, winner),
         {:ok, experiment} <- maybe_propose_experiment_winner(experiment, skill, report, winner) do
      {:ok, experiment}
    end
  end

  def propose_learning_from_run(%Run{} = run, opts \\ []) do
    run = Repo.preload(run, [:steps, :supervisor_agent])

    with :ok <- eligible_learning_run(run, opts),
         {:ok, skill} <- propose_from_run(run),
         :ok <- record_source_usage(run, skill) do
      create_improvement_proposal(%{
        workspace_id: run.workspace_id,
        target_skill_id: skill.id,
        source_run_id: run.id,
        kind: "create",
        proposed_snapshot: snapshot(skill),
        evaluation_report: Keyword.get(opts, :evaluation_report, default_learning_report(run)),
        confidence: Keyword.get(opts, :confidence, learning_confidence(run)),
        metadata: %{
          "created_by" => "learning_worker",
          "tool_count" => tool_count(run),
          "trigger" => learning_trigger(run)
        }
      })
    end
  end

  def approve_improvement_proposal(%ImprovementProposal{} = proposal, attrs \\ %{}) do
    proposal = Repo.preload(proposal, [:target_skill])
    attrs = stringify_keys(attrs)

    with %Skill{} = skill <- proposal.target_skill,
         {:ok, skill} <- apply_proposal_to_skill(proposal, skill, attrs),
         {:ok, proposal} <-
           update_improvement_proposal(proposal, %{
             "status" => attrs["status"] || "approved",
             "metadata" => Map.merge(proposal.metadata || %{}, approval_metadata(attrs))
           }) do
      {:ok, %{proposal: proposal, skill: skill}}
    else
      nil -> {:error, %{"reason" => "proposal_missing_target_skill"}}
      error -> error
    end
  end

  def reject_improvement_proposal(%ImprovementProposal{} = proposal, attrs \\ %{}) do
    update_improvement_proposal(proposal, %{
      "status" => "rejected",
      "metadata" => Map.merge(proposal.metadata || %{}, approval_metadata(stringify_keys(attrs)))
    })
  end

  def update_skill(%Skill{} = skill, attrs) do
    attrs = stringify_keys(attrs)

    Multi.new()
    |> Multi.update(:skill, Skill.changeset(skill, attrs))
    |> Multi.run(:version, fn repo, %{skill: skill} ->
      insert_version(repo, skill, "updated")
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{skill: skill}} -> {:ok, skill}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  def transition_skill(%Skill{} = skill, status, attrs \\ %{}) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("status", status)
      |> put_status_timestamp(status)

    Multi.new()
    |> Multi.update(:skill, skill |> Skill.changeset(attrs))
    |> Multi.run(:version, fn repo, %{skill: skill} ->
      insert_version(repo, skill, status)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{skill: skill}} -> {:ok, skill}
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  def activate_skill(%Skill{} = skill, attrs \\ %{}) do
    attrs = stringify_keys(attrs)

    cond do
      activation_override?(attrs) ->
        transition_skill(skill, "active", activation_override_attrs(skill, attrs))

      true ->
        case activation_gate(skill) do
          :ok -> transition_skill(skill, "active", attrs)
          {:error, message} -> {:error, activation_changeset(skill, message)}
        end
    end
  end

  def test_skill(%Skill{} = skill, attrs \\ %{}), do: transition_skill(skill, "testing", attrs)

  def deprecate_skill(%Skill{} = skill, attrs \\ %{}),
    do: transition_skill(skill, "deprecated", attrs)

  def archive_skill(%Skill{} = skill, attrs \\ %{}),
    do: transition_skill(skill, "archived", attrs)

  def propose_from_run(%Run{} = run) do
    run = Repo.preload(run, [:steps, :supervisor_agent])

    case get_skill_by_source_run_id(run.id) do
      %Skill{} = skill ->
        {:ok, skill}

      nil ->
        create_skill(%{
          workspace_id: run.workspace_id,
          owner_agent_id: run.supervisor_agent_id,
          source_run_id: run.id,
          name: proposal_name(run),
          slug: "run-#{run.id}-skill",
          description: proposal_description(run),
          instructions: proposal_instructions(run),
          trigger_conditions: %{"source" => "run_review", "run_id" => run.id},
          required_tools: proposal_tools(run),
          memory_scopes: proposal_scopes(run, :memory),
          knowledge_scopes: proposal_scopes(run, :knowledge),
          provenance: %{
            "kind" => "run_skill_proposal",
            "source_run_id" => run.id,
            "source_run_title" => run.title
          }
        })
    end
  end

  def list_versions(%Skill{} = skill), do: list_versions(skill.id)

  def list_versions(skill_id) do
    SkillVersion
    |> where([version], version.skill_id == ^skill_id)
    |> order_by([version], desc: version.version)
    |> Repo.all()
  end

  def activation_gate(%Skill{} = skill) do
    case eval_threshold(skill) do
      nil ->
        :ok

      threshold ->
        with {:ok, suite} <- attached_eval_suite(skill),
             {:ok, report} <- latest_eval_report(skill, suite),
             :ok <- pass_rate_meets_threshold(report, threshold) do
          :ok
        end
    end
  end

  def export_markdown(%Skill{} = skill) do
    frontmatter =
      %{
        "name" => skill.name,
        "slug" => skill.slug,
        "status" => skill.status,
        "required_tools" => skill.required_tools || [],
        "memory_scopes" => skill.memory_scopes || [],
        "knowledge_scopes" => skill.knowledge_scopes || []
      }
      |> Jason.encode!(pretty: true)

    """
    ---
    #{frontmatter}
    ---
    # #{skill.name}

    #{skill.description}

    ## When To Use

    #{inspect(skill.trigger_conditions || %{})}

    ## Procedure

    #{skill.instructions}

    ## Verification

    #{inspect(skill.evals || %{})}
    """
    |> String.trim()
  end

  def import_markdown(workspace_id, markdown, attrs \\ %{}) when is_binary(markdown) do
    attrs = stringify_keys(attrs)
    parsed = parse_skill_markdown(markdown)

    create_skill(%{
      workspace_id: workspace_id,
      name: attrs["name"] || parsed["name"] || "Imported Skill",
      slug:
        attrs["slug"] || parsed["slug"] ||
          slugify(attrs["name"] || parsed["name"] || "imported-skill"),
      description: attrs["description"] || parsed["description"] || "Imported skill.",
      instructions: attrs["instructions"] || parsed["instructions"] || markdown,
      required_tools: attrs["required_tools"] || parsed["required_tools"] || [],
      memory_scopes: attrs["memory_scopes"] || parsed["memory_scopes"] || ["workspace"],
      knowledge_scopes: attrs["knowledge_scopes"] || parsed["knowledge_scopes"] || ["workspace"],
      provenance: attrs["provenance"] || %{"kind" => "skill_markdown_import"}
    })
  end

  defp maybe_auto_activate_proposal({:ok, %ImprovementProposal{} = proposal}),
    do: maybe_auto_activate_proposal(proposal)

  defp maybe_auto_activate_proposal(%ImprovementProposal{} = proposal) do
    proposal = Repo.preload(proposal, [:target_skill])

    cond do
      proposal.status != "draft" ->
        {:ok, proposal}

      auto_activation_allowed?(proposal) ->
        case approve_improvement_proposal(proposal, %{
               "status" => "auto_activated",
               "actor" => "skill_learning_worker",
               "reason" => "safe skill passed autonomous activation policy"
             }) do
          {:ok, %{proposal: proposal}} -> {:ok, proposal}
          {:error, _error} -> {:ok, proposal}
        end

      true ->
        {:ok, proposal}
    end
  end

  defp auto_activation_allowed?(%ImprovementProposal{target_skill: %Skill{} = skill} = proposal) do
    policy = skill_autonomy_policy(skill.workspace_id)

    proposal.kind in ["create", "refine"] and policy["mode"] == "auto_activate_safe" and
      safe_skill?(skill) and
      proposal.confidence >= policy["minimum_confidence"] and
      evaluation_passes?(proposal.evaluation_report || %{}, policy)
  end

  defp auto_activation_allowed?(_proposal), do: false

  defp skill_autonomy_policy(workspace_id) do
    workspace = HydraAgent.Runtime.get_workspace!(workspace_id)

    defaults = %{
      "mode" => "auto_activate_safe",
      "minimum_eval_pass_rate" => 0.85,
      "minimum_eval_cases" => 3,
      "minimum_confidence" => 0.8
    }

    Map.merge(defaults, get_in(workspace.settings || %{}, ["skill_autonomy"]) || %{})
  end

  defp safe_skill?(%Skill{} = skill) do
    skill.required_tools
    |> List.wrap()
    |> Enum.all?(fn tool_name ->
      case Registry.get(tool_name) do
        {_module, spec} -> spec.side_effect_class == "read_only"
        nil -> false
      end
    end)
  end

  defp evaluation_passes?(report, policy) do
    pass_rate = get_in(report, ["quality", "pass_rate"]) || report["pass_rate"] || 0.0
    case_count = get_in(report, ["quality", "case_count"]) || report["case_count"] || 0

    pass_rate >= policy["minimum_eval_pass_rate"] and case_count >= policy["minimum_eval_cases"]
  end

  defp apply_proposal_to_skill(%ImprovementProposal{kind: "prune"}, %Skill{} = skill, attrs) do
    archive_skill(skill, attrs)
  end

  defp apply_proposal_to_skill(
         %ImprovementProposal{kind: kind} = proposal,
         %Skill{} = skill,
         attrs
       )
       when kind in ["create", "refine"] do
    snapshot = stringify_keys(proposal.proposed_snapshot || %{})

    skill
    |> update_skill(%{
      name: snapshot["name"] || skill.name,
      slug: snapshot["slug"] || skill.slug,
      description: snapshot["description"] || skill.description,
      instructions: snapshot["instructions"] || skill.instructions,
      trigger_conditions: snapshot["trigger_conditions"] || skill.trigger_conditions,
      required_tools: snapshot["required_tools"] || skill.required_tools,
      memory_scopes: snapshot["memory_scopes"] || skill.memory_scopes,
      knowledge_scopes: snapshot["knowledge_scopes"] || skill.knowledge_scopes,
      evals: Map.merge(skill.evals || %{}, snapshot["evals"] || %{}),
      provenance: proposal_provenance(skill, snapshot, proposal)
    })
    |> case do
      {:ok, skill} ->
        if attrs["status"] == "auto_activated" do
          activate_skill(skill, %{
            "override_activation_gate" => true,
            "override_actor" => attrs["actor"] || "skill_learning_worker",
            "override_reason" => attrs["reason"] || "safe auto activation"
          })
        else
          {:ok, skill}
        end

      error ->
        error
    end
  end

  defp update_improvement_proposal(%ImprovementProposal{} = proposal, attrs) do
    proposal
    |> ImprovementProposal.changeset(attrs)
    |> Repo.update()
  end

  defp refinement_snapshot(skill, attrs) do
    allowed =
      attrs
      |> Map.take(
        ~w(name slug description instructions trigger_conditions required_tools memory_scopes knowledge_scopes evals provenance)
      )

    skill
    |> snapshot()
    |> Map.merge(allowed)
    |> Map.update("provenance", %{"kind" => "skill_refinement"}, fn provenance ->
      Map.merge(skill.provenance || %{}, provenance || %{})
    end)
  end

  defp manual_proposal_report(kind) do
    %{
      "quality" => %{"pass_rate" => 0.0, "case_count" => 0},
      "source" => "manual_#{kind}_proposal",
      "requires_review" => true
    }
  end

  defp proposal_provenance(skill, snapshot, proposal) do
    (skill.provenance || %{})
    |> Map.merge(snapshot["provenance"] || %{})
    |> Map.update("improvement_proposals", [proposal.id], fn proposal_ids ->
      proposal_ids
      |> list_or_empty()
      |> Enum.concat([proposal.id])
      |> Enum.uniq()
    end)
  end

  defp list_or_empty(values) when is_list(values), do: values
  defp list_or_empty(_values), do: []

  defp approval_metadata(attrs) do
    %{
      "actor" => attrs["actor"] || "operator",
      "reason" => attrs["reason"] || "proposal review",
      "reviewed_at" => DateTime.to_iso8601(now())
    }
  end

  defp eligible_learning_run(run, opts) do
    minimum_tool_count = Keyword.get(opts, :minimum_tool_count, 5)

    cond do
      existing_learning_proposal?(run) ->
        {:error, %{"reason" => "learning_proposal_exists", "run_id" => run.id}}

      tool_count(run) >= minimum_tool_count ->
        :ok

      recovery_run?(run) ->
        :ok

      true ->
        {:error,
         %{
           "reason" => "run_not_learning_eligible",
           "run_id" => run.id,
           "tool_count" => tool_count(run)
         }}
    end
  end

  defp existing_learning_proposal?(run) do
    ImprovementProposal
    |> where([proposal], proposal.source_run_id == ^run.id)
    |> Repo.exists?()
  end

  defp record_source_usage(run, skill) do
    case record_usage_event(%{
           workspace_id: run.workspace_id,
           skill_id: skill.id,
           agent_id: run.supervisor_agent_id,
           run_id: run.id,
           trigger_text: run.goal,
           match_score: 1.0,
           outcome_status: if(run.status == "failed", do: "failure", else: "success"),
           tool_count: tool_count(run),
           error_summary: get_in(run.result || %{}, ["error", "reason"]),
           metadata: %{"source" => "learning_worker"}
         }) do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp eligible_learning_conversation(conversation, opts) do
    minimum_turn_count = opt(opts, :minimum_turn_count, 4)

    cond do
      existing_conversation_learning_proposal?(conversation) ->
        {:error, %{"reason" => "learning_proposal_exists", "conversation_id" => conversation.id}}

      length(conversation.turns || []) >= minimum_turn_count ->
        :ok

      true ->
        {:error,
         %{
           "reason" => "conversation_not_learning_eligible",
           "conversation_id" => conversation.id,
           "turn_count" => length(conversation.turns || [])
         }}
    end
  end

  defp eligible_learning_room(room, messages, opts) do
    minimum_message_count = opt(opts, :minimum_message_count, 4)

    cond do
      existing_room_learning_proposal?(room) ->
        {:error, %{"reason" => "learning_proposal_exists", "room_id" => room.id}}

      length(messages) >= minimum_message_count ->
        :ok

      true ->
        {:error,
         %{
           "reason" => "room_not_learning_eligible",
           "room_id" => room.id,
           "message_count" => length(messages)
         }}
    end
  end

  defp existing_conversation_learning_proposal?(conversation) do
    ImprovementProposal
    |> where([proposal], proposal.source_conversation_id == ^conversation.id)
    |> Repo.exists?()
  end

  defp existing_room_learning_proposal?(room) do
    ImprovementProposal
    |> where([proposal], proposal.source_room_id == ^room.id)
    |> Repo.exists?()
  end

  defp record_conversation_usage(conversation, skill) do
    case record_usage_event(%{
           workspace_id: conversation.workspace_id,
           skill_id: skill.id,
           agent_id: conversation.agent_id,
           conversation_id: conversation.id,
           trigger_text: conversation.title || conversation.channel,
           match_score: 1.0,
           outcome_status: "success",
           tool_count: length(conversation_tools(conversation)),
           metadata: %{"source" => "conversation_learning_worker"}
         }) do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp record_room_usage(room, messages, skill) do
    case record_usage_event(%{
           workspace_id: room.workspace_id,
           skill_id: skill.id,
           agent_id: room.coordinator_agent_id,
           room_id: room.id,
           trigger_text: room.title || room.slug,
           match_score: 1.0,
           outcome_status: "success",
           tool_count: length(room_tools(messages)),
           metadata: %{"source" => "room_learning_worker", "message_count" => length(messages)}
         }) do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp conversation_learning_report(conversation) do
    %{
      "quality" => %{"pass_rate" => 1.0, "case_count" => max(length(conversation.turns || []), 1)},
      "source" => "conversation_outcome_heuristic"
    }
  end

  defp room_learning_report(messages) do
    %{
      "quality" => %{"pass_rate" => 1.0, "case_count" => max(length(messages), 1)},
      "source" => "room_outcome_heuristic"
    }
  end

  defp conversation_learning_confidence(conversation),
    do: min(1.0, 0.55 + length(conversation.turns || []) / 20)

  defp room_learning_confidence(messages), do: min(1.0, 0.55 + length(messages) / 20)

  defp conversation_proposal_name(conversation) do
    conversation.title
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Conversation #{conversation.id} Skill"
      title -> String.slice("#{title} Skill", 0, 120)
    end
  end

  defp conversation_proposal_description(conversation) do
    "Proposed procedural skill extracted from conversation #{conversation.id}."
  end

  defp conversation_proposal_instructions(conversation) do
    turns =
      conversation.turns
      |> List.wrap()
      |> Enum.reject(&(&1.role == "system"))
      |> Enum.map(fn turn ->
        "- #{turn.role}: #{summarize_text(turn.content, 220)}"
      end)
      |> Enum.join("\n")

    """
    Reuse the successful pattern observed in conversation #{conversation.id}.

    Transcript evidence:
    #{turns}

    Procedure:
    1. Recognize a similar request from the user or channel context.
    2. Preserve the useful sequence of questions, actions, checks, and final answer shape.
    3. Re-run the verification steps that made the conversation successful.
    4. Record any durable lessons as reviewed memory or knowledge only after provenance is clear.
    """
    |> String.trim()
  end

  defp room_proposal_name(room) do
    room.title
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Room #{room.id} Skill"
      title -> String.slice("#{title} Skill", 0, 120)
    end
  end

  defp room_proposal_description(room) do
    "Proposed multi-agent skill extracted from room #{room.id}."
  end

  defp room_proposal_instructions(room, messages) do
    transcript =
      messages
      |> Enum.map(fn message ->
        author = (message.agent && message.agent.name) || message.author_type
        "- #{author}: #{summarize_text(message.content, 220)}"
      end)
      |> Enum.join("\n")

    """
    Reuse the group-chat coordination pattern observed in room #{room.id}.

    Transcript evidence:
    #{transcript}

    Procedure:
    1. Identify the agents or perspectives needed for the request.
    2. Preserve the useful handoff, critique, and synthesis sequence.
    3. Keep user-visible replies concise while retaining internal provenance.
    4. Escalate side-effecting actions to approval before execution.
    """
    |> String.trim()
  end

  defp conversation_tools(conversation) do
    conversation.turns
    |> List.wrap()
    |> Enum.flat_map(fn turn ->
      [turn.metadata["tool_name"], turn.metadata["tool"], turn.metadata["name"]]
    end)
    |> Enum.filter(&known_tool?/1)
    |> Enum.uniq()
  end

  defp room_tools(messages) do
    messages
    |> List.wrap()
    |> Enum.flat_map(fn message ->
      [message.metadata["tool_name"], message.metadata["tool"], message.metadata["name"]]
    end)
    |> Enum.filter(&known_tool?/1)
    |> Enum.uniq()
  end

  defp known_tool?(tool_name) when is_binary(tool_name), do: Registry.get(tool_name) != nil
  defp known_tool?(_tool_name), do: false

  defp eval_generation_examples(skill, attrs) do
    explicit_examples = normalize_examples(attrs["examples"] || [])

    source_examples =
      skill
      |> source_examples_for_skill()
      |> Enum.take(6)

    explicit_examples ++ source_examples
  end

  defp source_examples_for_skill(skill) do
    provenance = skill.provenance || %{}

    cond do
      provenance["source_run_id"] ->
        run_examples(provenance["source_run_id"])

      provenance["source_conversation_id"] ->
        conversation_examples(provenance["source_conversation_id"])

      provenance["source_room_id"] ->
        room_examples(provenance["source_room_id"])

      true ->
        []
    end
  end

  defp run_examples(run_id) do
    run =
      run_id
      |> normalize_id()
      |> Runtime.get_run_detail!()

    run.steps
    |> List.wrap()
    |> Enum.map(fn step ->
      %{
        "name" => step.title || "Run step #{step.index}",
        "prompt" => step.title || inspect(step.input || %{}),
        "expected" => %{
          "contains" => keywords("#{step.title} #{step.status} #{step.tool_name}", ["complete"])
        },
        "metadata" => %{"source" => "run_step", "run_id" => run.id, "step_id" => step.id}
      }
    end)
  rescue
    _error -> []
  end

  defp conversation_examples(conversation_id) do
    conversation =
      conversation_id
      |> normalize_id()
      |> Runtime.get_conversation!()

    conversation.turns
    |> List.wrap()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [left, right] -> left.role == "user" and right.role == "assistant" end)
    |> Enum.map(fn [user, assistant] ->
      %{
        "name" => "Conversation #{conversation.id} example",
        "prompt" => user.content,
        "expected" => %{"contains" => keywords(assistant.content, ["answer"])},
        "metadata" => %{
          "source" => "conversation_turns",
          "conversation_id" => conversation.id,
          "assistant_turn_id" => assistant.id
        }
      }
    end)
  rescue
    _error -> []
  end

  defp room_examples(room_id) do
    room =
      room_id
      |> normalize_id()
      |> Rooms.get_room!()

    room
    |> Rooms.list_messages(limit: 100)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [left, right] ->
      left.author_type == "user" and right.author_type in ["agent", "system"]
    end)
    |> Enum.map(fn [user, response] ->
      %{
        "name" => "Room #{room.id} example",
        "prompt" => user.content,
        "expected" => %{"contains" => keywords(response.content, ["answer"])},
        "metadata" => %{
          "source" => "room_messages",
          "room_id" => room.id,
          "response_message_id" => response.id
        }
      }
    end)
  rescue
    _error -> []
  end

  defp normalize_examples(examples) when is_list(examples) do
    examples
    |> Enum.map(&stringify_keys/1)
    |> Enum.filter(&is_binary(&1["prompt"]))
  end

  defp normalize_examples(_examples), do: []

  defp generated_example_cases(skill, examples) do
    examples
    |> Enum.with_index(1)
    |> Enum.map(fn {example, index} ->
      expected = example["expected"] || %{"contains" => keywords(example["prompt"], ["result"])}

      %{
        "name" => example["name"] || "#{skill.name} real example #{index}",
        "slug" => "example-#{skill.slug}-#{index}",
        "prompt" => example["prompt"],
        "expected" => expected,
        "scoring" => example["scoring"] || %{"type" => "contains"},
        "metadata" =>
          Map.merge(
            %{"capability" => "real_example_regression", "skill_id" => skill.id},
            example["metadata"] || %{}
          )
      }
    end)
  end

  defp generated_eval_cases(%Skill{} = skill, examples) do
    instruction_keywords = keywords(skill.instructions, ["procedure"])

    tool_keywords =
      if skill.required_tools == [], do: ["no external tools"], else: skill.required_tools

    [
      %{
        "name" => "Recognize when to use #{skill.name}",
        "slug" => "recognize-#{skill.slug}",
        "prompt" =>
          "A user request matches these conditions: #{inspect(skill.trigger_conditions || %{})}. Explain whether to use the #{skill.name} skill and why.",
        "expected" => %{"contains" => keywords(skill.name, ["skill"])},
        "metadata" => %{"capability" => "skill_trigger_recognition"}
      },
      %{
        "name" => "Follow #{skill.name} procedure",
        "slug" => "follow-#{skill.slug}-procedure",
        "prompt" =>
          "Use the #{skill.name} skill procedure to outline the first safe actions. Procedure: #{skill.instructions}",
        "expected" => %{"contains" => instruction_keywords},
        "metadata" => %{"capability" => "skill_procedure_fidelity"}
      },
      %{
        "name" => "Respect #{skill.name} tool boundaries",
        "slug" => "respect-#{skill.slug}-tools",
        "prompt" => "List the tools and boundaries for the #{skill.name} skill before acting.",
        "expected" => %{"contains" => tool_keywords},
        "metadata" => %{"capability" => "skill_tool_boundary"}
      }
    ] ++ generated_example_cases(skill, examples)
  end

  defp upsert_eval_suite(workspace_id, %{"slug" => slug} = attrs) do
    case Repo.get_by(Suite, workspace_id: workspace_id, slug: slug) do
      nil -> Evals.create_suite(attrs)
      suite -> suite |> Suite.changeset(attrs) |> Repo.update()
    end
  end

  defp upsert_eval_cases(suite, case_specs) do
    results =
      Enum.map(case_specs, fn spec ->
        attrs =
          spec
          |> Map.take(~w(name slug prompt expected metadata))
          |> Map.merge(%{
            "workspace_id" => suite.workspace_id,
            "suite_id" => suite.id,
            "scoring" => spec["scoring"] || %{"type" => "contains"}
          })

        case Repo.get_by(Case, suite_id: suite.id, slug: spec["slug"]) do
          nil -> Evals.create_case(suite, attrs)
          eval_case -> eval_case |> Case.changeset(attrs) |> Repo.update()
        end
      end)

    errors = Enum.filter(results, &match?({:error, _error}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, eval_case} -> eval_case end)}
    else
      {:error, Enum.map(errors, fn {:error, error} -> error end)}
    end
  end

  defp validate_code_skill_slug(slug) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, slug) do
      :ok
    else
      {:error, %{"reason" => "invalid_code_skill_slug", "slug" => slug}}
    end
  end

  defp project_skill_root(workspace_id, attrs) do
    workspace = Runtime.get_workspace!(workspace_id)
    project_root = attrs["project_root"] || get_in(workspace.settings || %{}, ["project_root"])

    root =
      project_root
      |> case do
        nil -> File.cwd!()
        value -> Path.expand(to_string(value))
      end
      |> Path.join(".hydra/skills")

    {:ok, root}
  end

  defp normalize_code_skill_files(files) when is_map(files) do
    results =
      Enum.map(files, fn {path, content} ->
        path = path |> to_string() |> String.replace("\\", "/")
        content = to_string(content)

        cond do
          Path.type(path) == :absolute or String.contains?(path, "..") ->
            {:error, %{"reason" => "unsafe_skill_file_path", "path" => path}}

          not allowed_skill_file_path?(path) ->
            {:error, %{"reason" => "unsupported_skill_file_path", "path" => path}}

          byte_size(content) > 1_048_576 ->
            {:error, %{"reason" => "skill_file_too_large", "path" => path}}

          true ->
            {:ok, {path, content}}
        end
      end)

    case Enum.find(results, &match?({:error, _error}, &1)) do
      {:error, error} -> {:error, error}
      nil -> {:ok, Enum.map(results, fn {:ok, file} -> file end)}
    end
  end

  defp normalize_code_skill_files(_files), do: {:error, %{"reason" => "files_must_be_map"}}

  defp allowed_skill_file_path?("SKILL.md"), do: true

  defp allowed_skill_file_path?(path) do
    [dir | _rest] = String.split(path, "/", parts: 2)
    dir in ~w(references templates scripts assets)
  end

  defp write_code_skill_files(skill_dir, slug, attrs, files) do
    File.mkdir_p!(skill_dir)

    skill_markdown =
      files
      |> Enum.find_value(fn
        {"SKILL.md", content} -> content
        _other -> nil
      end) ||
        code_skill_markdown(slug, attrs)

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_markdown)

    files
    |> Enum.reject(fn {path, _content} -> path == "SKILL.md" end)
    |> Enum.each(fn {path, content} ->
      target = Path.join(skill_dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
    end)

    :ok
  end

  defp code_skill_markdown(slug, attrs) do
    """
    ---
    name: #{slug}
    description: #{attrs["description"] || "Project-local Hydra code skill."}
    version: 1.0.0
    author: Hydra Agent
    license: project-local
    ---

    # #{attrs["name"] || titleize(slug)}

    ## Overview

    #{attrs["description"] || "Project-local code skill created by Hydra."}

    ## When To Use

    #{inspect(attrs["trigger_conditions"] || %{"source" => "project_code_skill"})}

    ## Procedure

    #{attrs["instructions"] || "Use the supporting files in this directory as implementation references. Keep execution policy-gated."}

    ## Verification

    Run the attached script or eval suite in an approved sandbox before activation.
    """
    |> String.trim()
  end

  defp infer_import_source_type(%{"source_type" => source_type}) when is_binary(source_type),
    do: source_type

  defp infer_import_source_type(%{"markdown" => markdown}) when is_binary(markdown), do: "raw"

  defp infer_import_source_type(%{"source_url" => source_url}) when is_binary(source_url) do
    if String.contains?(source_url, "github.com"), do: "github", else: "raw"
  end

  defp infer_import_source_type(%{"repo_url" => _repo_url}), do: "github"
  defp infer_import_source_type(_attrs), do: "local_path"

  defp materialize_skill_import_source("local_path", attrs) do
    path = attrs["path"] || attrs["source_path"]
    skill_path = path && Path.expand(path)

    cond do
      is_nil(skill_path) ->
        {:error, %{"reason" => "skill_import_path_missing"}}

      File.dir?(skill_path) ->
        {:ok, skill_path, %{"source_path" => skill_path}}

      true ->
        {:error, %{"reason" => "skill_import_path_not_found", "path" => skill_path}}
    end
  end

  defp materialize_skill_import_source("raw", attrs) do
    markdown = attrs["markdown"]

    if is_binary(markdown) and String.trim(markdown) != "" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "hydra-skill-import-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "SKILL.md"), markdown)
      Process.put(:hydra_skill_import_tmp_dir, tmp_dir)
      {:ok, tmp_dir, %{"source_url" => attrs["source_url"], "source_path" => "SKILL.md"}}
    else
      {:error, %{"reason" => "raw_skill_markdown_missing"}}
    end
  end

  defp materialize_skill_import_source("github", attrs) do
    repo_url = attrs["repo_url"] || attrs["source_url"]
    repo_ref = attrs["ref"] || attrs["source_ref"] || "HEAD"
    repo_path = attrs["path"] || attrs["source_path"] || "."

    with :ok <- validate_safe_relative_path(repo_path),
         true <-
           (is_binary(repo_url) and repo_url != "") ||
             {:error, %{"reason" => "github_repo_url_missing"}},
         :ok <- validate_github_repo_url(repo_url),
         {:ok, checkout_dir} <- clone_skill_import_repo(repo_url, repo_ref),
         skill_path <- Path.expand(repo_path, checkout_dir),
         true <-
           String.starts_with?(skill_path, checkout_dir) ||
             {:error, %{"reason" => "unsafe_skill_import_path"}},
         true <-
           File.dir?(skill_path) ||
             {:error, %{"reason" => "github_skill_path_not_found", "path" => repo_path}} do
      {:ok, skill_path,
       %{"source_url" => repo_url, "source_path" => repo_path, "source_ref" => repo_ref}}
    end
  end

  defp materialize_skill_import_source(source_type, _attrs),
    do: {:error, %{"reason" => "unsupported_skill_import_source", "source_type" => source_type}}

  defp clone_skill_import_repo(repo_url, repo_ref) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "hydra-skill-import-#{System.unique_integer([:positive])}")

    case System.cmd("git", ["clone", "--depth", "1", repo_url, tmp_dir], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.put(:hydra_skill_import_tmp_dir, tmp_dir)

        if repo_ref in [nil, "", "HEAD"] do
          {:ok, tmp_dir}
        else
          case System.cmd("git", ["-C", tmp_dir, "checkout", repo_ref], stderr_to_stdout: true) do
            {_output, 0} ->
              {:ok, tmp_dir}

            {output, _status} ->
              {:error, %{"reason" => "github_ref_checkout_failed", "detail" => output}}
          end
        end

      {output, _status} ->
        {:error, %{"reason" => "github_clone_failed", "detail" => output}}
    end
  end

  defp cleanup_skill_import_source(nil), do: :ok
  defp cleanup_skill_import_source(path), do: File.rm_rf(path)

  defp scan_skill_path(skill_path, attrs) do
    with {:ok, instruction_file} <- skill_instruction_file(skill_path, attrs),
         {:ok, markdown} <- File.read(instruction_file.path),
         {:ok, manifest, contents} <- scan_skill_files(skill_path, attrs) do
      parsed = parse_import_instructions(markdown, instruction_file)
      name = attrs["name"] || parsed["name"] || titleize(Path.basename(skill_path))
      slug = attrs["slug"] || parsed["slug"] || slugify(name)
      required_tools = attrs["required_tools"] || parsed["required_tools"] || []

      warnings =
        required_tools
        |> scan_skill_warnings(manifest, contents)
        |> maybe_add_warning(
          instruction_file.format != "skill_md",
          "info",
          "compat_instruction_file",
          "#{instruction_file.relative_path} imported as a compatible instruction file"
        )

      {:ok,
       %{
         skill_attrs: %{
           "name" => name,
           "slug" => slug,
           "description" => attrs["description"] || parsed["description"] || "Imported skill.",
           "instructions" => attrs["instructions"] || parsed["instructions"] || markdown,
           "trigger_conditions" =>
             parsed["trigger_conditions"] ||
               %{
                 "source" => "skill_hub_import",
                 "instruction_file" => instruction_file.relative_path,
                 "format" => instruction_file.format
               },
           "required_tools" => required_tools,
           "memory_scopes" => parsed["memory_scopes"] || ["workspace"],
           "knowledge_scopes" => parsed["knowledge_scopes"] || ["workspace"],
           "status" => attrs["status"] || "proposed"
         },
         file_manifest: manifest,
         warnings: warnings,
         scan_result: %{
           "file_count" => length(manifest),
           "total_bytes" => Enum.reduce(manifest, 0, &(&1["bytes"] + &2)),
           "format" => "#{instruction_file.format}_directory",
           "instruction_file" => instruction_file.relative_path
         }
       }}
    end
  end

  defp skill_instruction_file(skill_path, attrs) do
    candidates =
      case attrs["instruction_file"] || attrs["skill_file"] do
        file when is_binary(file) and file != "" -> [file]
        _file -> @skill_import_instruction_files
      end

    candidates
    |> Enum.reduce_while(nil, fn relative_path, _acc ->
      case validate_safe_relative_path(relative_path) do
        :ok ->
          path = Path.join(skill_path, relative_path)

          if File.regular?(path) do
            {:halt,
             %{
               path: path,
               relative_path: relative_path,
               format: instruction_file_format(relative_path)
             }}
          else
            {:cont, nil}
          end

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      nil -> {:error, %{"reason" => "skill_instruction_file_missing", "candidates" => candidates}}
      file -> {:ok, file}
    end
  end

  defp instruction_file_format("SKILL.md"), do: "skill_md"
  defp instruction_file_format("AGENTS.md"), do: "agents_md"
  defp instruction_file_format("CLAUDE.md"), do: "claude_md"
  defp instruction_file_format("README.md"), do: "readme_md"
  defp instruction_file_format(path), do: path |> Path.basename() |> slugify()

  defp scan_skill_files(skill_path, attrs) do
    max_files = parse_positive_int(attrs["max_files"], 64)
    max_bytes = parse_positive_int(attrs["max_bytes"], 512_000)

    files =
      skill_path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    if length(files) > max_files do
      {:error, %{"reason" => "skill_import_too_many_files", "count" => length(files)}}
    else
      read_skill_files(skill_path, files, max_bytes)
    end
  end

  defp read_skill_files(skill_path, files, max_bytes) do
    Enum.reduce_while(files, {:ok, [], %{}, 0}, fn file, {:ok, manifest, contents, total} ->
      relative = Path.relative_to(file, skill_path)
      stat = File.stat!(file)
      next_total = total + stat.size

      cond do
        not safe_relative_path?(relative) ->
          {:halt, {:error, %{"reason" => "unsafe_skill_import_file", "path" => relative}}}

        next_total > max_bytes ->
          {:halt, {:error, %{"reason" => "skill_import_too_large", "bytes" => next_total}}}

        true ->
          content = File.read!(file)

          entry = %{
            "path" => relative,
            "bytes" => stat.size,
            "sha256" => sha256(content),
            "executable" => executable_skill_file?(file, relative)
          }

          {:cont, {:ok, manifest ++ [entry], Map.put(contents, relative, content), next_total}}
      end
    end)
    |> case do
      {:ok, manifest, contents, _total} -> {:ok, manifest, contents}
      error -> error
    end
  end

  defp scan_skill_warnings(required_tools, manifest, contents) do
    unknown_tool_warnings =
      required_tools
      |> List.wrap()
      |> Enum.reject(&known_tool?/1)
      |> Enum.map(fn tool ->
        %{"severity" => "warning", "code" => "unknown_tool", "message" => "Unknown tool #{tool}"}
      end)

    file_warnings =
      Enum.flat_map(manifest, fn file ->
        content = Map.get(contents, file["path"], "")

        []
        |> maybe_add_warning(
          file["executable"],
          "warning",
          "executable_file",
          "#{file["path"]} is executable"
        )
        |> maybe_add_warning(
          network_hint?(content),
          "info",
          "network_hint",
          "#{file["path"]} references network access"
        )
        |> maybe_add_warning(
          secret_hint?(content),
          "warning",
          "secret_hint",
          "#{file["path"]} may contain a secret-looking value"
        )
      end)

    unknown_tool_warnings ++ file_warnings
  end

  defp maybe_add_warning(warnings, true, severity, code, message),
    do: warnings ++ [%{"severity" => severity, "code" => code, "message" => message}]

  defp maybe_add_warning(warnings, _condition, _severity, _code, _message), do: warnings

  defp executable_skill_file?(file, relative) do
    executable_bit? =
      case File.stat(file) do
        {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
        _error -> false
      end

    executable_ext? = Path.extname(relative) in [".sh", ".py", ".js", ".ts", ".exs"]
    executable_bit? or executable_ext?
  end

  defp network_hint?(content),
    do: Regex.match?(~r/(Req\.|HTTPoison|fetch\(|requests\.|curl\s|wget\s)/, content)

  defp secret_hint?(content),
    do: Regex.match?(~r/(api[_-]?key|secret|token)\s*[:=]\s*["'][^"']{12,}/i, content)

  defp validate_safe_relative_path(path) do
    if safe_relative_path?(path),
      do: :ok,
      else: {:error, %{"reason" => "unsafe_skill_import_path"}}
  end

  defp validate_github_repo_url(repo_url) when is_binary(repo_url) do
    cond do
      String.starts_with?(repo_url, "https://github.com/") ->
        :ok

      String.starts_with?(repo_url, "git@github.com:") ->
        :ok

      true ->
        {:error, %{"reason" => "unsupported_github_repo_url"}}
    end
  end

  defp validate_github_repo_url(_repo_url), do: {:error, %{"reason" => "github_repo_url_missing"}}

  defp safe_relative_path?(path) when is_binary(path) do
    path == "." or
      (Path.type(path) != :absolute and
         path
         |> Path.split()
         |> Enum.all?(&(&1 not in ["..", ""])))
  end

  defp safe_relative_path?(_path), do: false

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

  defp supporting_skill_files(skill_path) do
    skill_path
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == "SKILL.md"))
    |> Enum.map(fn file ->
      relative = Path.relative_to(file, skill_path)

      %{
        "path" => relative,
        "bytes" => File.stat!(file).size,
        "sha256" => sha256(File.read!(file))
      }
    end)
  end

  defp experiment_examples(skill, attrs) do
    examples = normalize_examples(attrs["examples"] || [])
    if examples == [], do: source_examples_for_skill(skill), else: examples
  end

  defp experiment_candidates(skill, attrs) do
    baseline = snapshot(skill) |> Map.put("experiment_candidate", "baseline")

    variants =
      attrs["variants"]
      |> case do
        variants when is_list(variants) and variants != [] ->
          variants

        _variants ->
          [
            %{
              "name" => "#{skill.name} Verification Variant",
              "instructions" =>
                skill.instructions <>
                  "\n\nBefore finalizing, explicitly verify the result against the source evidence and tool boundaries."
            },
            %{
              "name" => "#{skill.name} Concise Variant",
              "instructions" =>
                skill.instructions <>
                  "\n\nPrefer the shortest complete answer that preserves provenance and next actions."
            }
          ]
      end

    variant_snapshots =
      variants
      |> Enum.with_index(1)
      |> Enum.map(fn {variant, index} ->
        variant = stringify_keys(variant)

        baseline
        |> Map.merge(variant)
        |> Map.put("experiment_candidate", variant["candidate"] || "variant_#{index}")
      end)

    [baseline | variant_snapshots]
  end

  defp validate_safe_experiment(candidates) do
    unsafe =
      Enum.reject(candidates, fn candidate ->
        candidate
        |> Map.get("required_tools", [])
        |> Enum.all?(&read_only_tool?/1)
      end)

    if unsafe == [] do
      :ok
    else
      {:error,
       %{
         "reason" => "unsafe_experiment_candidate",
         "candidates" => Enum.map(unsafe, & &1["experiment_candidate"])
       }}
    end
  end

  defp read_only_tool?(tool_name) do
    case Registry.get(tool_name) do
      {_module, spec} -> spec.side_effect_class == "read_only"
      nil -> false
    end
  end

  defp evaluate_candidates(candidates, examples) do
    reports =
      Enum.map(candidates, fn candidate ->
        score = candidate_score(candidate, examples)

        %{
          "candidate" => candidate["experiment_candidate"],
          "name" => candidate["name"],
          "score" => score,
          "pass_rate" => score,
          "case_count" => max(length(examples), 1)
        }
      end)

    %{
      "source" => "safe_skill_variant_experiment",
      "quality" => %{
        "case_count" => max(length(examples), 1),
        "pass_rate" => reports |> Enum.map(& &1["pass_rate"]) |> Enum.max(fn -> 0.0 end)
      },
      "candidates" => reports
    }
  end

  defp candidate_score(candidate, []),
    do: min(1.0, 0.6 + String.length(candidate["instructions"] || "") / 2000)

  defp candidate_score(candidate, examples) do
    haystack =
      "#{candidate["name"]} #{candidate["description"]} #{candidate["instructions"]}"
      |> String.downcase()

    hits =
      Enum.count(examples, fn example ->
        expected_keywords(example)
        |> Enum.any?(&String.contains?(haystack, String.downcase(to_string(&1))))
      end)

    hits / max(length(examples), 1)
  end

  defp expected_keywords(example) do
    get_in(example, ["expected", "contains"]) || keywords(example["prompt"], ["answer"])
  end

  defp winner_candidate(report) do
    report["candidates"]
    |> Enum.max_by(& &1["score"], fn -> %{"candidate" => "baseline"} end)
    |> Map.fetch!("candidate")
  end

  defp create_experiment(skill, attrs, candidates, report, winner) do
    winner_snapshot =
      Enum.find(candidates, &(&1["experiment_candidate"] == winner)) || List.first(candidates)

    %Experiment{}
    |> Experiment.changeset(%{
      workspace_id: skill.workspace_id,
      skill_id: skill.id,
      source_conversation_id: attrs["source_conversation_id"],
      source_room_id: attrs["source_room_id"],
      status: "completed",
      candidate_snapshots: %{"candidates" => candidates},
      evaluation_report: report,
      winner_snapshot: winner_snapshot || %{},
      metadata: %{
        "created_by" => attrs["created_by"] || "skill_experiment_worker",
        "example_count" => length(experiment_examples(skill, attrs))
      }
    })
    |> Repo.insert()
  end

  defp maybe_propose_experiment_winner(experiment, _skill, _report, "baseline"),
    do: {:ok, experiment}

  defp maybe_propose_experiment_winner(experiment, skill, report, _winner) do
    with {:ok, proposal} <-
           create_refinement_proposal(skill, %{
             "name" => experiment.winner_snapshot["name"],
             "description" => experiment.winner_snapshot["description"],
             "instructions" => experiment.winner_snapshot["instructions"],
             "required_tools" => experiment.winner_snapshot["required_tools"],
             "evaluation_report" => experiment_report_for_proposal(report, experiment),
             "confidence" => get_in(report, ["quality", "pass_rate"]) || 0.0,
             "metadata" => %{
               "created_by" => "skill_experiment_worker",
               "experiment_id" => experiment.id,
               "winner" => experiment.winner_snapshot["experiment_candidate"]
             }
           }) do
      experiment
      |> Experiment.changeset(%{selected_proposal_id: proposal.id})
      |> Repo.update()
    end
  end

  defp experiment_report_for_proposal(report, experiment) do
    Map.merge(report, %{
      "experiment_id" => experiment.id,
      "quality" =>
        Map.merge(report["quality"] || %{}, %{
          "case_count" => max(get_in(report, ["quality", "case_count"]) || 0, 3)
        })
    })
  end

  defp seed_skill(workspace_id, spec) do
    attrs =
      spec
      |> Map.put("workspace_id", workspace_id)
      |> Map.put_new("status", "proposed")
      |> Map.put("provenance", %{
        "kind" => "standard_skill_pack",
        "seeded_by" => "hydra_v4"
      })

    case Repo.get_by(Skill, workspace_id: workspace_id, slug: spec["slug"]) do
      nil -> create_skill(attrs)
      %Skill{} = skill -> maybe_update_seed_skill(skill, attrs)
    end
  end

  defp maybe_update_seed_skill(%Skill{} = skill, attrs) do
    comparable_attrs = Map.drop(attrs, ["workspace_id", "status"])

    current =
      skill
      |> snapshot()
      |> Map.take(Map.keys(comparable_attrs))

    if current == comparable_attrs do
      {:ok, skill}
    else
      update_skill(skill, comparable_attrs)
    end
  end

  defp keywords(value, fallback) do
    value
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(3)
    |> case do
      [] -> fallback
      words -> words
    end
  end

  defp default_learning_report(run) do
    %{
      "quality" => %{
        "pass_rate" => if(run.status == "failed", do: 0.0, else: 1.0),
        "case_count" => max(tool_count(run), 1)
      },
      "source" => "run_outcome_heuristic"
    }
  end

  defp learning_confidence(run), do: min(1.0, 0.55 + tool_count(run) / 20)

  defp learning_trigger(run) do
    cond do
      recovery_run?(run) -> "recovery_run"
      tool_count(run) >= 5 -> "multi_tool_run"
      true -> "manual"
    end
  end

  defp recovery_run?(run) do
    run.steps
    |> List.wrap()
    |> Enum.any?(fn step ->
      step.status in ["failed", "blocked"] or map_size(step.error || %{}) > 0 or
        map_size(step.approval || %{}) > 0
    end)
  end

  defp tool_count(run), do: run.steps |> List.wrap() |> Enum.count(& &1.tool_name)

  defp parse_skill_markdown(markdown) do
    [head | _rest] = String.split(markdown, "\n---\n", parts: 2)

    with true <- String.starts_with?(head, "---\n"),
         {:ok, attrs} <- parse_frontmatter(String.trim_leading(head, "---\n")) do
      attrs
    else
      _other ->
        %{
          "name" =>
            markdown
            |> String.split("\n")
            |> Enum.find(&String.starts_with?(&1, "# "))
            |> title_from_heading(),
          "description" => "Imported skill.",
          "instructions" => markdown
        }
    end
  end

  defp parse_import_instructions(markdown, %{format: "skill_md"}),
    do: parse_skill_markdown(markdown)

  defp parse_import_instructions(markdown, instruction_file) do
    parsed = parse_skill_markdown(markdown)
    heading = title_from_first_heading(markdown)
    base_name = instruction_file.relative_path |> Path.rootname() |> titleize()

    parsed
    |> Map.put_new("name", heading || base_name)
    |> Map.put_new(
      "description",
      "#{instruction_file.relative_path} compatible instruction import."
    )
    |> Map.put_new("instructions", markdown)
    |> Map.put_new("trigger_conditions", %{
      "source" => "skill_hub_compatible_import",
      "instruction_file" => instruction_file.relative_path,
      "format" => instruction_file.format
    })
  end

  defp parse_frontmatter(frontmatter) do
    case Jason.decode(frontmatter) do
      {:ok, attrs} when is_map(attrs) -> {:ok, attrs}
      _json_error -> {:ok, parse_simple_yaml(frontmatter)}
    end
  end

  defp parse_simple_yaml(frontmatter) do
    frontmatter
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), parse_yaml_scalar(String.trim(value)))
        _other -> acc
      end
    end)
  end

  defp parse_yaml_scalar("[" <> rest) do
    rest
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"") |> String.trim("'")))
  end

  defp parse_yaml_scalar(value), do: value |> String.trim("\"") |> String.trim("'")

  defp title_from_heading(nil), do: nil
  defp title_from_heading("# " <> title), do: String.trim(title)

  defp title_from_first_heading(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "# "))
    |> title_from_heading()
  end

  defp titleize(value) do
    value
    |> to_string()
    |> String.replace("-", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp summarize_text(value, max_length) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_length)
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "imported-skill"
      slug -> slug
    end
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value) do
    where(query, [row], field(row, ^field) == ^normalize_id(value))
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [skill], skill.status == ^status)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp opt(opts, key, default), do: opt(opts, key) || default

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> id
    end
  end

  defp normalize_id(id), do: id

  defp put_status_timestamp(attrs, "active"), do: Map.put_new(attrs, "activated_at", now())
  defp put_status_timestamp(attrs, "deprecated"), do: Map.put_new(attrs, "deprecated_at", now())
  defp put_status_timestamp(attrs, _status), do: attrs

  defp activation_override?(attrs) do
    attrs["override_activation_gate"] in [true, "true", "1", 1]
  end

  defp activation_override_attrs(skill, attrs) do
    override = %{
      "actor" => attrs["override_actor"] || attrs["actor"] || "operator",
      "reason" => override_reason(attrs),
      "overridden_at" => DateTime.to_iso8601(now())
    }

    provenance =
      (skill.provenance || %{})
      |> Map.update("activation_overrides", [override], fn overrides ->
        if is_list(overrides), do: overrides ++ [override], else: [override]
      end)

    %{"provenance" => provenance}
  end

  defp override_reason(attrs) do
    attrs
    |> Map.get("override_reason", attrs["reason"])
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "operator override"
      reason -> reason
    end
  end

  defp activation_changeset(skill, message) do
    skill
    |> Skill.changeset(%{})
    |> Changeset.add_error(:evals, message)
  end

  defp attached_eval_suite(skill) do
    suite_ref = eval_meta(skill, "suite_id")

    cond do
      is_nil(suite_ref) ->
        {:error, "activation requires an attached eval suite when a threshold is declared"}

      true ->
        suite =
          skill.workspace_id
          |> Evals.list_suites()
          |> Enum.find(&suite_matches?(&1, suite_ref))

        if suite do
          {:ok, suite}
        else
          {:error, "activation requires an existing eval suite when a threshold is declared"}
        end
    end
  end

  defp latest_eval_report(%{owner_agent_id: nil}, _suite) do
    {:error, "activation requires an owner agent to evaluate thresholded skills"}
  end

  defp latest_eval_report(skill, suite) do
    case Evals.list_runs(skill.workspace_id,
           agent_id: skill.owner_agent_id,
           suite_id: suite.id,
           limit: 1
         ) do
      [run | _runs] -> {:ok, Evals.report(run)}
      [] -> {:error, "activation requires at least one eval run for the attached suite"}
    end
  end

  defp pass_rate_meets_threshold(report, threshold) do
    pass_rate = get_in(report, ["quality", "pass_rate"]) || 0.0

    if pass_rate >= threshold do
      :ok
    else
      {:error,
       "activation requires latest eval pass rate #{percent(pass_rate)} to meet #{percent(threshold)} threshold"}
    end
  end

  defp suite_matches?(suite, ref) when is_integer(ref), do: suite.id == ref

  defp suite_matches?(suite, ref) when is_binary(ref) do
    suite.slug == ref or suite.name == ref or to_string(suite.id) == ref
  end

  defp suite_matches?(_suite, _ref), do: false

  defp eval_threshold(skill) do
    case eval_meta(skill, "threshold") do
      value when is_float(value) or is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value)
      _value -> nil
    end
  end

  defp eval_meta(skill, key) do
    evals = skill.evals || %{}

    evals
    |> Map.get(key)
    |> case do
      nil -> Map.get(evals, eval_atom_key(key))
      value -> value
    end
  end

  defp eval_atom_key("suite_id"), do: :suite_id
  defp eval_atom_key("threshold"), do: :threshold
  defp eval_atom_key(_key), do: nil

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _error -> nil
    end
  end

  defp percent(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp percent(value), do: to_string(value)

  defp insert_version(repo, skill, change_kind) do
    next_version =
      SkillVersion
      |> where([version], version.skill_id == ^skill.id)
      |> select([version], max(version.version))
      |> repo.one()
      |> case do
        nil -> 1
        version -> version + 1
      end

    %SkillVersion{}
    |> SkillVersion.changeset(%{
      workspace_id: skill.workspace_id,
      skill_id: skill.id,
      version: next_version,
      change_kind: change_kind,
      status: skill.status,
      snapshot: snapshot(skill),
      metadata: %{}
    })
    |> repo.insert()
  end

  defp snapshot(skill) do
    %{
      "name" => skill.name,
      "slug" => skill.slug,
      "description" => skill.description,
      "status" => skill.status,
      "instructions" => skill.instructions,
      "trigger_conditions" => skill.trigger_conditions || %{},
      "required_tools" => skill.required_tools || [],
      "memory_scopes" => skill.memory_scopes || [],
      "knowledge_scopes" => skill.knowledge_scopes || [],
      "evals" => skill.evals || %{},
      "provenance" => skill.provenance || %{},
      "owner_agent_id" => skill.owner_agent_id,
      "source_run_id" => skill.source_run_id,
      "activated_at" => datetime(skill.activated_at),
      "deprecated_at" => datetime(skill.deprecated_at)
    }
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp proposal_name(run) do
    run.title
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Run #{run.id} Skill"
      title -> String.slice("#{title} Skill", 0, 120)
    end
  end

  defp proposal_description(run) do
    goal = run.goal |> to_string() |> String.trim()

    if goal == "" do
      "Proposed procedural skill extracted from run #{run.id}."
    else
      String.slice("Proposed procedural skill extracted from run #{run.id}: #{goal}", 0, 280)
    end
  end

  defp proposal_instructions(run) do
    steps =
      run.steps
      |> Enum.map(fn step ->
        tool =
          [step.tool_name, step.side_effect_class]
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" / ")

        suffix = if tool == "", do: "", else: " (#{tool})"
        "- #{step.title}#{suffix}"
      end)

    [
      "Review and refine this proposed skill before activation.",
      "",
      "Source run: #{run.title}",
      "Goal: #{run.goal}",
      "",
      "Observed procedure:",
      if(steps == [], do: "- No run steps were captured.", else: Enum.join(steps, "\n"))
    ]
    |> Enum.join("\n")
  end

  defp proposal_tools(run) do
    known_tools = Registry.names()

    run.steps
    |> Enum.map(& &1.tool_name)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1 in known_tools))
    |> Enum.uniq()
  end

  defp proposal_scopes(run, scope) do
    metadata_scopes =
      (run.metadata || %{})
      |> Map.get("#{scope}_scopes", [])
      |> List.wrap()

    if metadata_scopes == [], do: ["workspace"], else: metadata_scopes
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(value), do: value

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
