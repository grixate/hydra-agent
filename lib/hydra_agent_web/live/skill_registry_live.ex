defmodule HydraAgentWeb.SkillRegistryLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Evals, Runtime, Skills}
  alias HydraAgent.Skills.Skill
  alias HydraAgentWeb.ControlShell

  @statuses ["all" | Skill.statuses()]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Skills Registry")
     |> assign(:workspace_id, nil)
     |> assign(:status, "all")
     |> assign(:statuses, @statuses)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])
    status = status_param(params["status"])

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:status, status)
      |> load_workspace_state()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter-skills", params, socket) do
    params = stringify_keys(params)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/control/skills?workspace_id=#{socket.assigns.workspace_id}&status=#{status_param(params["status"])}"
     )}
  end

  def handle_event("test-skill", %{"id" => id}, socket) do
    id |> skill() |> Skills.test_skill() |> handle_skill_result(socket, "Skill moved to testing")
  end

  def handle_event("activate-skill", %{"id" => id}, socket) do
    id |> skill() |> Skills.activate_skill() |> handle_skill_result(socket, "Skill activated")
  end

  def handle_event("deprecate-skill", %{"id" => id}, socket) do
    id |> skill() |> Skills.deprecate_skill() |> handle_skill_result(socket, "Skill deprecated")
  end

  def handle_event("archive-skill", %{"id" => id}, socket) do
    id |> skill() |> Skills.archive_skill() |> handle_skill_result(socket, "Skill archived")
  end

  def handle_event("seed-standard-pack", _params, socket) do
    case Skills.seed_standard_skill_pack(socket.assigns.workspace_id) do
      {:ok, skills} ->
        {:noreply,
         socket
         |> put_flash(:info, "Seeded #{length(skills)} standard skills")
         |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Skill pack seeding failed: #{inspect(error)}")}
    end
  end

  def handle_event("generate-eval-suite", %{"id" => id}, socket) do
    case id |> skill() |> Skills.generate_eval_suite_for_skill() do
      {:ok, _result} ->
        {:noreply,
         socket |> put_flash(:info, "Skill eval suite generated") |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Eval generation failed: #{inspect(error)}")}
    end
  end

  def handle_event("run-experiment", %{"id" => id}, socket) do
    case id |> skill() |> Skills.run_skill_experiment(%{"created_by" => "skill_registry"}) do
      {:ok, experiment} ->
        message =
          if experiment.selected_proposal_id do
            "Skill experiment completed and drafted a winning refinement"
          else
            "Skill experiment completed; baseline remained strongest"
          end

        {:noreply, socket |> put_flash(:info, message) |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Skill experiment failed: #{inspect(error)}")}
    end
  end

  def handle_event("propose-refinement", %{"id" => id}, socket) do
    selected_skill = skill(id)

    case Skills.create_refinement_proposal(selected_skill, %{
           "description" => selected_skill.description,
           "instructions" => refinement_instructions(selected_skill),
           "metadata" => %{"created_by" => "skill_registry", "reason" => "operator refinement"}
         }) do
      {:ok, _proposal} ->
        {:noreply,
         socket |> put_flash(:info, "Refinement proposal drafted") |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Refinement proposal failed: #{inspect(error)}")}
    end
  end

  def handle_event("propose-prune", %{"id" => id}, socket) do
    case id
         |> skill()
         |> Skills.create_prune_proposal(%{
           "metadata" => %{"created_by" => "skill_registry", "reason" => "operator prune review"}
         }) do
      {:ok, _proposal} ->
        {:noreply, socket |> put_flash(:info, "Prune proposal drafted") |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Prune proposal failed: #{inspect(error)}")}
    end
  end

  def handle_event("approve-proposal", %{"id" => id}, socket) do
    proposal = id |> parse_id() |> Skills.get_improvement_proposal!()

    case Skills.approve_improvement_proposal(proposal, %{"actor" => "skill_registry"}) do
      {:ok, _result} ->
        {:noreply,
         socket |> put_flash(:info, "Skill proposal approved") |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Proposal approval failed: #{inspect(error)}")}
    end
  end

  def handle_event("reject-proposal", %{"id" => id}, socket) do
    proposal = id |> parse_id() |> Skills.get_improvement_proposal!()

    case Skills.reject_improvement_proposal(proposal, %{"actor" => "skill_registry"}) do
      {:ok, _proposal} ->
        {:noreply,
         socket |> put_flash(:info, "Skill proposal rejected") |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Proposal rejection failed: #{inspect(error)}")}
    end
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:skills, [])
    |> assign(:skill_counts, %{})
    |> assign(:agents_by_id, %{})
    |> assign(:skill_analytics, %{})
    |> assign(:improvement_proposals, [])
    |> assign(:usage_counts, %{})
    |> assign(:registry_analytics, empty_registry_analytics())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id, status: status}} = socket) do
    all_skills = Skills.list_skills(workspace_id)
    suites = Evals.list_suites(workspace_id)
    skill_analytics = skill_analytics(all_skills, suites)

    skills =
      if status == "all" do
        all_skills
      else
        Enum.filter(all_skills, &(&1.status == status))
      end

    agents_by_id =
      workspace_id
      |> Runtime.list_agents()
      |> Map.new(&{&1.id, &1})

    socket
    |> assign(:skills, skills)
    |> assign(:skill_counts, status_counts(all_skills))
    |> assign(:agents_by_id, agents_by_id)
    |> assign(:skill_analytics, skill_analytics)
    |> assign(
      :improvement_proposals,
      Skills.list_improvement_proposals(workspace_id, status: "draft")
    )
    |> assign(:usage_counts, skill_usage_counts(workspace_id))
    |> assign(:registry_analytics, registry_analytics(all_skills, skill_analytics))
  end

  defp handle_skill_result({:ok, _skill}, socket, message) do
    {:noreply, socket |> put_flash(:info, message) |> load_workspace_state()}
  end

  defp handle_skill_result({:error, changeset}, socket, _message) do
    {:noreply, put_flash(socket, :error, "Skill update failed: #{inspect(changeset.errors)}")}
  end

  defp selected_workspace_id([], _param), do: nil
  defp selected_workspace_id(workspaces, nil), do: workspaces |> List.first() |> Map.get(:id)

  defp selected_workspace_id(workspaces, workspace_id) do
    parsed_id = parse_id(workspace_id)

    if Enum.any?(workspaces, &(&1.id == parsed_id)) do
      parsed_id
    else
      workspaces |> List.first() |> Map.get(:id)
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp skill(id), do: id |> parse_id() |> Skills.get_skill!()

  defp refinement_instructions(skill) do
    base = skill.instructions |> to_string() |> String.trim()

    base <>
      "\n\nReview recent usage events, preserve tool boundaries, and add missing verification steps before activation."
  end

  defp status_param(status) when status in @statuses, do: status
  defp status_param(_status), do: "all"

  defp status_counts(skills), do: Enum.frequencies_by(skills, & &1.status)

  defp agent_name(nil, _agents_by_id), do: "unassigned"

  defp agent_name(agent_id, agents_by_id) do
    case Map.get(agents_by_id, agent_id) do
      nil -> "agent #{agent_id}"
      agent -> agent.name
    end
  end

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp eval_summary(evals) when evals in [%{}, nil], do: "no eval metadata"

  defp eval_summary(evals) do
    suite = evals["suite_id"] || evals[:suite_id] || "suite n/a"
    threshold = evals["threshold"] || evals[:threshold] || "threshold n/a"
    "#{suite} / #{threshold}"
  end

  defp skill_analytics(skills, suites) do
    Map.new(skills, fn skill ->
      {skill.id, skill_eval_analytics(skill, suites)}
    end)
  end

  defp skill_eval_analytics(skill, suites) do
    threshold = eval_threshold(skill)
    suite = eval_suite(skill, suites)
    report = latest_eval_report(skill, suite)
    pass_rate = report && get_in(report, ["quality", "pass_rate"])

    %{
      threshold: threshold,
      latest_pass_rate: pass_rate,
      latest_run_id: report && report["eval_run_id"],
      state: eval_state(threshold, pass_rate),
      override_count: activation_overrides(skill) |> length()
    }
  end

  defp registry_analytics(skills, analytics_by_skill) do
    analytics = Map.values(analytics_by_skill)

    %{
      total: length(skills),
      thresholded: Enum.count(analytics, &is_number(&1.threshold)),
      passing: Enum.count(analytics, &(&1.state == :passing)),
      blocked: Enum.count(analytics, &(&1.state == :blocked)),
      overrides: analytics |> Enum.map(& &1.override_count) |> Enum.sum()
    }
  end

  defp empty_registry_analytics do
    %{total: 0, thresholded: 0, passing: 0, blocked: 0, overrides: 0}
  end

  defp eval_suite(skill, suites) do
    suite_ref = eval_meta(skill, "suite_id")

    Enum.find(suites, fn suite ->
      suite_ref &&
        (suite.slug == suite_ref or suite.name == suite_ref or
           to_string(suite.id) == to_string(suite_ref))
    end)
  end

  defp latest_eval_report(%{owner_agent_id: nil}, _suite), do: nil
  defp latest_eval_report(_skill, nil), do: nil

  defp latest_eval_report(skill, suite) do
    skill.workspace_id
    |> Evals.list_runs(agent_id: skill.owner_agent_id, suite_id: suite.id, limit: 1)
    |> case do
      [run | _runs] -> Evals.report(run)
      [] -> nil
    end
  end

  defp eval_state(nil, _pass_rate), do: :not_thresholded
  defp eval_state(_threshold, nil), do: :missing
  defp eval_state(threshold, pass_rate) when pass_rate >= threshold, do: :passing
  defp eval_state(_threshold, _pass_rate), do: :blocked

  defp eval_threshold(skill) do
    case eval_meta(skill, "threshold") do
      value when is_float(value) or is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value)
      _value -> nil
    end
  end

  defp eval_meta(skill, key) do
    evals = skill.evals || %{}
    Map.get(evals, key) || Map.get(evals, String.to_atom(key))
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _error -> nil
    end
  end

  defp activation_overrides(skill) do
    case get_in(skill.provenance || %{}, ["activation_overrides"]) do
      overrides when is_list(overrides) -> overrides
      _overrides -> []
    end
  end

  defp skill_usage_counts(workspace_id) do
    workspace_id
    |> Skills.list_usage_events(limit: 500)
    |> Enum.frequencies_by(& &1.skill_id)
  end

  defp analytics_for(skill, analytics), do: Map.get(analytics, skill.id, %{})

  defp percent(nil), do: "n/a"
  defp percent(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp percent(value), do: to_string(value)

  defp eval_state_label(:passing), do: "passing"
  defp eval_state_label(:blocked), do: "below threshold"
  defp eval_state_label(:missing), do: "missing eval run"
  defp eval_state_label(:not_thresholded), do: "not thresholded"
  defp eval_state_label(_state), do: "unknown"

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @impl true
  def render(assigns) do
    ~H"""
    <section id="skills-registry" class="space-y-8">
      <ControlShell.header
        active={:skills}
        description="Review durable skills, lifecycle state, required tools, owning agents, eval metadata, and provenance."
        eyebrow="Learning loop"
        query={%{status: @status}}
        title="Skills Registry"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <form
          id="skills-filter-form"
          phx-change="filter-skills"
          class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-4 md:grid-cols-[220px_1fr_auto]"
        >
          <select
            id="skills-filter-status"
            name="status"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
          >
            <option :for={status <- @statuses} value={status} selected={status == @status}>
              {status}
            </option>
          </select>
          <p class="flex items-center text-sm text-zinc-500">
            {length(@skills)} visible / {Enum.sum(Map.values(@skill_counts))} total skills
          </p>
          <button
            id="skills-seed-standard-pack"
            type="button"
            phx-click="seed-standard-pack"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Seed Pack
          </button>
        </form>

        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
          <div
            :for={status <- Skill.statuses()}
            id={"skills-count-#{status}"}
            class="rounded-lg border border-zinc-200 bg-white p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">{status}</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {Map.get(@skill_counts, status, 0)}
            </p>
          </div>
        </div>

        <div id="skills-registry-analytics" class="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
              Thresholded
            </p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {@registry_analytics.thresholded}
            </p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Passing</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {@registry_analytics.passing}
            </p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
              Blocked
            </p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {@registry_analytics.blocked}
            </p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
              Overrides
            </p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {@registry_analytics.overrides}
            </p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
              Compared
            </p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {@registry_analytics.total}
            </p>
          </div>
        </div>

        <div id="skills-list" class="grid gap-4 xl:grid-cols-2">
          <article
            :for={skill <- @skills}
            id={"skill-card-#{skill.id}"}
            class="rounded-lg border border-zinc-200 bg-white p-5"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <p class="truncate text-lg font-semibold text-zinc-950">{skill.name}</p>
                <p class="mt-1 text-sm text-zinc-600">
                  {skill.status} / {agent_name(skill.owner_agent_id, @agents_by_id)}
                </p>
              </div>
              <.link
                navigate={~p"/control/skills/#{skill.id}?workspace_id=#{@workspace_id}"}
                class="rounded-md border border-zinc-200 px-3 py-2 text-xs font-semibold text-zinc-700 transition hover:border-zinc-400"
              >
                Open
              </.link>
            </div>

            <p class="mt-3 line-clamp-2 text-sm text-zinc-600">{skill.description}</p>

            <div class="mt-4 grid gap-3 text-sm text-zinc-600 md:grid-cols-2">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Tools
                </p>
                <p class="mt-1">{join_or_none(skill.required_tools || [])}</p>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">Eval</p>
                <p class="mt-1">{eval_summary(skill.evals)}</p>
              </div>
              <div class="md:col-span-2">
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Quality
                </p>
                <p class="mt-1">
                  latest pass {percent(analytics_for(skill, @skill_analytics).latest_pass_rate)} / {eval_state_label(
                    analytics_for(skill, @skill_analytics).state
                  )} / overrides {analytics_for(skill, @skill_analytics).override_count || 0}
                </p>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Usage
                </p>
                <p class="mt-1">{Map.get(@usage_counts, skill.id, 0)} observed events</p>
              </div>
            </div>

            <div class="mt-4 flex flex-wrap gap-2 border-t border-zinc-100 pt-4">
              <button
                id={"skill-test-#{skill.id}"}
                type="button"
                phx-click="test-skill"
                phx-value-id={skill.id}
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Test
              </button>
              <button
                id={"skill-activate-#{skill.id}"}
                type="button"
                phx-click="activate-skill"
                phx-value-id={skill.id}
                class="rounded-md border border-emerald-200 px-2 py-1 text-xs font-medium text-emerald-700 transition hover:border-emerald-400"
              >
                Activate
              </button>
              <button
                id={"skill-deprecate-#{skill.id}"}
                type="button"
                phx-click="deprecate-skill"
                phx-value-id={skill.id}
                class="rounded-md border border-amber-200 px-2 py-1 text-xs font-medium text-amber-700 transition hover:border-amber-400"
              >
                Deprecate
              </button>
              <button
                id={"skill-archive-#{skill.id}"}
                type="button"
                phx-click="archive-skill"
                phx-value-id={skill.id}
                class="rounded-md border border-red-200 px-2 py-1 text-xs font-medium text-red-700 transition hover:border-red-400"
              >
                Archive
              </button>
              <button
                id={"skill-generate-eval-#{skill.id}"}
                type="button"
                phx-click="generate-eval-suite"
                phx-value-id={skill.id}
                class="rounded-md border border-blue-200 px-2 py-1 text-xs font-medium text-blue-700 transition hover:border-blue-400"
              >
                Generate Eval
              </button>
              <button
                id={"skill-experiment-#{skill.id}"}
                type="button"
                phx-click="run-experiment"
                phx-value-id={skill.id}
                class="rounded-md border border-violet-200 px-2 py-1 text-xs font-medium text-violet-700 transition hover:border-violet-400"
              >
                Experiment
              </button>
              <button
                id={"skill-refine-#{skill.id}"}
                type="button"
                phx-click="propose-refinement"
                phx-value-id={skill.id}
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Refine
              </button>
              <button
                id={"skill-prune-#{skill.id}"}
                type="button"
                phx-click="propose-prune"
                phx-value-id={skill.id}
                class="rounded-md border border-red-200 px-2 py-1 text-xs font-medium text-red-700 transition hover:border-red-400"
              >
                Prune
              </button>
              <.link
                href={~p"/api/v1/skills/#{skill.id}/export_markdown"}
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Export
              </.link>
            </div>
          </article>

          <div
            :if={@skills == []}
            class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500"
          >
            No skills match this filter.
          </div>
        </div>

        <section
          id="skill-improvement-proposals"
          class="rounded-lg border border-zinc-200 bg-white p-5"
        >
          <div class="flex items-center justify-between gap-4">
            <div>
              <h2 class="text-base font-semibold text-zinc-950">Improvement Proposals</h2>
              <p class="mt-1 text-sm text-zinc-500">
                Draft skill creations, refinements, and pruning candidates from the learning loop.
              </p>
            </div>
            <span class="rounded-md bg-zinc-100 px-2 py-1 text-xs font-medium text-zinc-600">
              {length(@improvement_proposals)}
            </span>
          </div>
          <div class="mt-4 grid gap-3 xl:grid-cols-2">
            <div
              :for={proposal <- @improvement_proposals}
              id={"skill-improvement-proposal-#{proposal.id}"}
              class="rounded-lg border border-zinc-200 p-4"
            >
              <p class="text-sm font-semibold text-zinc-950">
                {proposal.kind} / {proposal.status}
              </p>
              <p class="mt-1 text-xs text-zinc-500">
                confidence {percent(proposal.confidence)} / skill {proposal.target_skill_id || "new"}
              </p>
              <p class="mt-2 line-clamp-2 text-sm text-zinc-600">
                {proposal.proposed_snapshot["description"] || "No description"}
              </p>
              <div class="mt-3 flex gap-2">
                <button
                  type="button"
                  phx-click="approve-proposal"
                  phx-value-id={proposal.id}
                  class="rounded-md border border-emerald-200 px-2 py-1 text-xs font-medium text-emerald-700"
                >
                  Approve
                </button>
                <button
                  type="button"
                  phx-click="reject-proposal"
                  phx-value-id={proposal.id}
                  class="rounded-md border border-red-200 px-2 py-1 text-xs font-medium text-red-700"
                >
                  Reject
                </button>
              </div>
            </div>
            <p :if={@improvement_proposals == []} class="text-sm text-zinc-500">
              No draft improvement proposals.
            </p>
          </div>
        </section>
      <% else %>
        <div class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </div>
      <% end %>
    </section>
    """
  end
end
