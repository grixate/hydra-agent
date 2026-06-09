defmodule HydraAgentWeb.SkillController do
  use HydraAgentWeb, :controller

  alias HydraAgent.{Runtime, Skills}

  def index(conn, %{"workspace_id" => workspace_id} = params) do
    skills = Skills.list_skills(workspace_id, status: params["status"])
    json(conn, %{data: Enum.map(skills, &skill_json/1)})
  end

  def show(conn, %{"id" => id}) do
    skill = Skills.get_skill!(id)
    json(conn, %{data: skill_json(skill)})
  end

  def usage(conn, %{"workspace_id" => workspace_id} = params) do
    events =
      Skills.list_usage_events(workspace_id,
        skill_id: params["skill_id"],
        run_id: params["run_id"],
        limit: 100
      )

    json(conn, %{data: Enum.map(events, &usage_event_json/1)})
  end

  def improvement_proposals(conn, %{"workspace_id" => workspace_id} = params) do
    proposals =
      Skills.list_improvement_proposals(workspace_id,
        status: params["status"],
        kind: params["kind"]
      )

    json(conn, %{data: Enum.map(proposals, &proposal_json/1)})
  end

  def experiments(conn, %{"workspace_id" => workspace_id} = params) do
    experiments =
      Skills.list_experiments(workspace_id,
        skill_id: params["skill_id"],
        status: params["status"]
      )

    json(conn, %{data: Enum.map(experiments, &experiment_json/1)})
  end

  def imports(conn, %{"workspace_id" => workspace_id} = params) do
    imports = Skills.list_skill_imports(workspace_id, status: params["status"])
    json(conn, %{data: Enum.map(imports, &skill_import_json/1)})
  end

  def evolve_due(conn, %{"workspace_id" => workspace_id} = params) do
    {:ok, summary} =
      Skills.evolve_due(workspace_id,
        minimum_tool_count: parse_int(params["minimum_tool_count"], 5),
        minimum_turn_count: parse_int(params["minimum_turn_count"], 4),
        minimum_message_count: parse_int(params["minimum_message_count"], 4)
      )

    conn |> put_status(:created) |> json(%{data: summary})
  end

  def scan_import(conn, %{"workspace_id" => workspace_id} = params) do
    case Skills.scan_skill_import(workspace_id, params) do
      {:ok, skill_import} ->
        conn |> put_status(:created) |> json(%{data: skill_import_json(skill_import)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def approve_import(conn, %{"import_id" => import_id} = params) do
    skill_import = Skills.get_skill_import!(import_id)

    case Skills.approve_skill_import(skill_import, params) do
      {:ok, result} ->
        json(conn, %{
          data: %{
            skill_import: skill_import_json(result.skill_import),
            skill: skill_json(result.skill)
          }
        })

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def reject_import(conn, %{"import_id" => import_id} = params) do
    skill_import = Skills.get_skill_import!(import_id)

    case Skills.reject_skill_import(skill_import, params) do
      {:ok, skill_import} ->
        json(conn, %{data: skill_import_json(skill_import)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def propose_from_run(conn, %{"workspace_id" => workspace_id, "run_id" => run_id} = params) do
    run = Runtime.get_run_for_workspace!(workspace_id, run_id)

    case Skills.propose_learning_from_run(run,
           minimum_tool_count: parse_int(params["minimum_tool_count"], 5),
           confidence: parse_float(params["confidence"], 0.85)
         ) do
      {:ok, proposal} ->
        conn |> put_status(:created) |> json(%{data: proposal_json(proposal)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def propose_from_conversation(
        conn,
        %{"workspace_id" => workspace_id, "conversation_id" => conversation_id} = params
      ) do
    conversation = Runtime.get_conversation!(conversation_id)

    if to_string(conversation.workspace_id) == to_string(workspace_id) do
      case Skills.propose_learning_from_conversation(conversation,
             minimum_turn_count: parse_int(params["minimum_turn_count"], 4),
             confidence: parse_float(params["confidence"], 0.85)
           ) do
        {:ok, proposal} ->
          conn |> put_status(:created) |> json(%{data: proposal_json(proposal)})

        {:error, error} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
      end
    else
      conn |> put_status(:not_found) |> json(%{errors: %{reason: "conversation_not_found"}})
    end
  end

  def propose_from_room(conn, %{"workspace_id" => workspace_id, "room_id" => room_id} = params) do
    room = HydraAgent.Rooms.get_room_for_workspace!(workspace_id, room_id)

    case Skills.propose_learning_from_room(room,
           minimum_message_count: parse_int(params["minimum_message_count"], 4),
           confidence: parse_float(params["confidence"], 0.85)
         ) do
      {:ok, proposal} ->
        conn |> put_status(:created) |> json(%{data: proposal_json(proposal)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def seed_pack(conn, %{"workspace_id" => workspace_id} = params) do
    case Skills.seed_standard_skill_pack(workspace_id, params) do
      {:ok, skills} ->
        conn |> put_status(:created) |> json(%{data: Enum.map(skills, &skill_json/1)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def create_code_skill(conn, %{"workspace_id" => workspace_id} = params) do
    case Skills.create_project_code_skill(workspace_id, params) do
      {:ok, skill} ->
        conn |> put_status(:created) |> json(%{data: skill_json(skill)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def import_directory(conn, %{"workspace_id" => workspace_id, "path" => path} = params) do
    case Skills.import_skill_directory(workspace_id, path, params) do
      {:ok, skill} ->
        conn |> put_status(:created) |> json(%{data: skill_json(skill)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def refine_proposal(conn, %{"id" => id} = params) do
    id
    |> Skills.get_skill!()
    |> Skills.create_refinement_proposal(params)
    |> render_created_proposal_result(conn)
  end

  def prune_proposal(conn, %{"id" => id} = params) do
    id
    |> Skills.get_skill!()
    |> Skills.create_prune_proposal(params)
    |> render_created_proposal_result(conn)
  end

  def generate_eval_suite(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)

    case Skills.generate_eval_suite_for_skill(skill, params) do
      {:ok, %{skill: skill, suite: suite}} ->
        conn
        |> put_status(:created)
        |> json(%{data: %{skill: skill_json(skill), suite: suite_json(suite)}})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def run_experiment(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)

    case Skills.run_skill_experiment(skill, params) do
      {:ok, experiment} ->
        conn |> put_status(:created) |> json(%{data: experiment_json(experiment)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def restore_version(conn, %{"id" => id, "version" => version} = params) do
    skill = Skills.get_skill!(id)

    case Skills.restore_skill_version(skill, version, params) do
      {:ok, skill} ->
        json(conn, %{data: skill_json(skill)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def approve_proposal(conn, %{"id" => id} = params) do
    proposal = Skills.get_improvement_proposal!(id)

    case Skills.approve_improvement_proposal(proposal, params) do
      {:ok, result} ->
        json(conn, %{
          data: %{proposal: proposal_json(result.proposal), skill: skill_json(result.skill)}
        })

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  def reject_proposal(conn, %{"id" => id} = params) do
    proposal = Skills.get_improvement_proposal!(id)
    render_proposal_result(conn, Skills.reject_improvement_proposal(proposal, params))
  end

  def create(conn, params) do
    case Skills.create_skill(params) do
      {:ok, skill} ->
        conn
        |> put_status(:created)
        |> json(%{data: skill_json(skill)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors_json(changeset)})
    end
  end

  def activate(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.activate_skill(skill, params))
  end

  def test(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.test_skill(skill, params))
  end

  def deprecate(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.deprecate_skill(skill, params))
  end

  def archive(conn, %{"id" => id} = params) do
    skill = Skills.get_skill!(id)
    render_result(conn, Skills.archive_skill(skill, params))
  end

  def export_markdown(conn, %{"id" => id}) do
    skill = Skills.get_skill!(id)
    text(conn, Skills.export_markdown(skill))
  end

  def import_markdown(conn, %{"workspace_id" => workspace_id, "markdown" => markdown} = params) do
    case Skills.import_markdown(workspace_id, markdown, params) do
      {:ok, skill} ->
        conn |> put_status(:created) |> json(%{data: skill_json(skill)})

      {:error, error} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors_json(error)})
    end
  end

  defp render_result(conn, {:ok, skill}), do: json(conn, %{data: skill_json(skill)})

  defp render_result(conn, {:error, changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors_json(changeset)})
  end

  defp render_proposal_result(conn, {:ok, proposal}),
    do: json(conn, %{data: proposal_json(proposal)})

  defp render_proposal_result(conn, {:error, error}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors_json(error)})
  end

  defp render_created_proposal_result({:ok, proposal}, conn),
    do: conn |> put_status(:created) |> json(%{data: proposal_json(proposal)})

  defp render_created_proposal_result({:error, error}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors_json(error)})
  end

  defp skill_json(skill) do
    %{
      id: skill.id,
      workspace_id: skill.workspace_id,
      owner_agent_id: skill.owner_agent_id,
      source_run_id: skill.source_run_id,
      name: skill.name,
      slug: skill.slug,
      description: skill.description,
      status: skill.status,
      instructions: skill.instructions,
      trigger_conditions: skill.trigger_conditions,
      required_tools: skill.required_tools,
      memory_scopes: skill.memory_scopes,
      knowledge_scopes: skill.knowledge_scopes,
      evals: skill.evals,
      provenance: skill.provenance,
      activated_at: skill.activated_at,
      deprecated_at: skill.deprecated_at
    }
  end

  defp skill_import_json(skill_import) do
    %{
      id: skill_import.id,
      workspace_id: skill_import.workspace_id,
      installed_skill_id: skill_import.installed_skill_id,
      source_type: skill_import.source_type,
      source_url: skill_import.source_url,
      source_path: skill_import.source_path,
      source_ref: skill_import.source_ref,
      status: skill_import.status,
      skill_attrs: skill_import.skill_attrs,
      file_manifest: skill_import.file_manifest,
      scan_result: skill_import.scan_result,
      warnings: skill_import.warnings,
      approved_by: skill_import.approved_by,
      approved_at: skill_import.approved_at,
      metadata: skill_import.metadata,
      inserted_at: skill_import.inserted_at,
      updated_at: skill_import.updated_at
    }
  end

  defp usage_event_json(event) do
    %{
      id: event.id,
      workspace_id: event.workspace_id,
      skill_id: event.skill_id,
      agent_id: event.agent_id,
      run_id: event.run_id,
      conversation_id: event.conversation_id,
      room_id: event.room_id,
      trigger_text: event.trigger_text,
      match_score: event.match_score,
      outcome_status: event.outcome_status,
      tool_count: event.tool_count,
      error_summary: event.error_summary,
      metadata: event.metadata,
      inserted_at: event.inserted_at
    }
  end

  defp proposal_json(proposal) do
    metadata = proposal.metadata || %{}

    %{
      id: proposal.id,
      workspace_id: proposal.workspace_id,
      target_skill_id: proposal.target_skill_id,
      source_run_id: proposal.source_run_id,
      source_conversation_id: proposal.source_conversation_id,
      source_room_id: proposal.source_room_id,
      kind: proposal.kind,
      status: proposal.status,
      proposed_snapshot: proposal.proposed_snapshot,
      evaluation_report: proposal.evaluation_report,
      confidence: proposal.confidence,
      policy_decision: metadata["policy_decision"],
      policy_snapshot: metadata["policy_snapshot"],
      auto_activation_reason: metadata["auto_activation_reason"],
      source_summary: source_summary(proposal),
      metadata: proposal.metadata,
      inserted_at: proposal.inserted_at
    }
  end

  defp experiment_json(experiment) do
    %{
      id: experiment.id,
      workspace_id: experiment.workspace_id,
      skill_id: experiment.skill_id,
      source_conversation_id: experiment.source_conversation_id,
      source_room_id: experiment.source_room_id,
      selected_proposal_id: experiment.selected_proposal_id,
      status: experiment.status,
      candidate_snapshots: experiment.candidate_snapshots,
      evaluation_report: experiment.evaluation_report,
      winner_snapshot: experiment.winner_snapshot,
      metadata: experiment.metadata,
      inserted_at: experiment.inserted_at
    }
  end

  defp suite_json(suite) do
    %{
      id: suite.id,
      workspace_id: suite.workspace_id,
      name: suite.name,
      slug: suite.slug,
      description: suite.description,
      status: suite.status,
      metadata: suite.metadata,
      cases: Enum.map((Ecto.assoc_loaded?(suite.cases) && suite.cases) || [], &case_json/1)
    }
  end

  defp case_json(eval_case) do
    %{
      id: eval_case.id,
      suite_id: eval_case.suite_id,
      name: eval_case.name,
      slug: eval_case.slug,
      prompt: eval_case.prompt,
      expected: eval_case.expected,
      scoring: eval_case.scoring,
      metadata: eval_case.metadata
    }
  end

  defp source_summary(proposal) do
    cond do
      proposal.source_room_id -> "room:#{proposal.source_room_id}"
      proposal.source_conversation_id -> "conversation:#{proposal.source_conversation_id}"
      proposal.source_run_id -> "run:#{proposal.source_run_id}"
      true -> "manual"
    end
  end

  defp errors_json(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp errors_json(error) when is_map(error), do: error
  defp errors_json(error), do: %{detail: inspect(error)}

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> integer
      _other -> default
    end
  end

  defp parse_float(nil, default), do: default

  defp parse_float(value, default) do
    case Float.parse(to_string(value)) do
      {float, ""} -> float
      _other -> default
    end
  end
end
