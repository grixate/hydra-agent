defmodule HydraAgentWeb.SkillDetailLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Evals, Runtime, Skills, Usage}
  alias HydraAgentWeb.ControlShell

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Skill Detail")
     |> assign(:workspace_id, nil)
     |> assign(:skill, nil)
     |> assign(:owner_agent, nil)
     |> assign(:source_run, nil)
     |> assign(:usage_summary, empty_usage_summary())
     |> assign(:eval_suite, nil)
     |> assign(:eval_reports, [])
     |> assign(:skill_versions, [])
     |> assign(:editing_skill, false)
     |> assign(:skill_form_attrs, empty_skill_form_attrs())
     |> assign(:skill_form_errors, %{})
     |> load_workspaces()}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    skill = Skills.get_skill!(id)

    workspace_id =
      selected_workspace_id(
        socket.assigns.workspaces,
        params["workspace_id"] || skill.workspace_id
      )

    workspace_id =
      if workspace_id == skill.workspace_id, do: workspace_id, else: skill.workspace_id

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:skill, skill)
      |> assign(:editing_skill, false)
      |> assign(:skill_form_errors, %{})
      |> load_skill_state()

    {:noreply, socket}
  end

  @impl true
  def handle_event("test-skill", _params, socket) do
    socket.assigns.skill
    |> Skills.test_skill()
    |> handle_skill_result(socket, "Skill moved to testing")
  end

  def handle_event("activate-skill", _params, socket) do
    socket.assigns.skill
    |> Skills.activate_skill()
    |> handle_skill_result(socket, "Skill activated")
  end

  def handle_event("override-activate-skill", %{"override" => attrs}, socket) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("override_activation_gate", true)
      |> Map.put("override_actor", "skill_detail")

    socket.assigns.skill
    |> Skills.activate_skill(attrs)
    |> handle_skill_result(socket, "Skill activated with operator override")
  end

  def handle_event("deprecate-skill", _params, socket) do
    socket.assigns.skill
    |> Skills.deprecate_skill()
    |> handle_skill_result(socket, "Skill deprecated")
  end

  def handle_event("archive-skill", _params, socket) do
    socket.assigns.skill
    |> Skills.archive_skill()
    |> handle_skill_result(socket, "Skill archived")
  end

  def handle_event("edit-skill", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_skill, true)
     |> assign(:skill_form_attrs, skill_form_attrs(socket.assigns.skill))
     |> assign(:skill_form_errors, %{})}
  end

  def handle_event("cancel-edit-skill", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_skill, false)
     |> assign(:skill_form_attrs, skill_form_attrs(socket.assigns.skill))
     |> assign(:skill_form_errors, %{})}
  end

  def handle_event("save-skill", %{"skill" => attrs}, socket) do
    case parse_skill_form_attrs(attrs) do
      {:ok, attrs} ->
        case Skills.update_skill(socket.assigns.skill, attrs) do
          {:ok, skill} ->
            {:noreply,
             socket
             |> assign(:skill, skill)
             |> assign(:editing_skill, false)
             |> assign(:skill_form_errors, %{})
             |> put_flash(:info, "Skill updated")
             |> load_skill_state()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:skill_form_attrs, attrs_to_form(attrs))
             |> assign(:skill_form_errors, changeset_errors(changeset))
             |> assign(:editing_skill, true)}
        end

      {:error, form_attrs, form_errors} ->
        {:noreply,
         socket
         |> assign(:skill_form_attrs, form_attrs)
         |> assign(:skill_form_errors, form_errors)
         |> assign(:editing_skill, true)}
    end
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_skill_state(%{assigns: %{skill: skill}} = socket) do
    owner_agent =
      if skill.owner_agent_id do
        Runtime.get_agent!(skill.owner_agent_id)
      end

    source_run =
      if skill.source_run_id do
        Runtime.get_run!(skill.source_run_id)
      end

    socket
    |> assign(:page_title, skill.name)
    |> assign(:skill, Skills.get_skill!(skill.id))
    |> assign(:owner_agent, owner_agent)
    |> assign(:source_run, source_run)
    |> assign(:usage_summary, usage_summary(skill))
    |> assign(:eval_suite, eval_suite(skill))
    |> assign(:eval_reports, eval_reports(skill))
    |> assign(:skill_versions, Skills.list_versions(skill))
    |> assign(:skill_form_attrs, skill_form_attrs(Skills.get_skill!(skill.id)))
  end

  defp handle_skill_result({:ok, skill}, socket, message) do
    {:noreply,
     socket
     |> assign(:skill, skill)
     |> put_flash(:info, message)
     |> load_skill_state()}
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

  defp parse_id(_id), do: nil

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp timestamp(nil), do: "n/a"
  defp timestamp(datetime), do: Calendar.strftime(datetime, "%m-%d %H:%M")

  defp compact_json(map) when map in [%{}, nil], do: "{}"

  defp compact_json(map) when is_map(map) do
    map
    |> Jason.encode!()
    |> String.slice(0, 600)
  end

  defp empty_skill_form_attrs do
    %{
      "name" => "",
      "slug" => "",
      "description" => "",
      "instructions" => "",
      "required_tools" => "",
      "memory_scopes" => "",
      "knowledge_scopes" => "",
      "trigger_conditions" => "{}",
      "evals" => "{}",
      "provenance" => "{}"
    }
  end

  defp skill_form_attrs(nil), do: empty_skill_form_attrs()

  defp skill_form_attrs(skill) do
    %{
      "name" => skill.name || "",
      "slug" => skill.slug || "",
      "description" => skill.description || "",
      "instructions" => skill.instructions || "",
      "required_tools" => list_to_input(skill.required_tools),
      "memory_scopes" => list_to_input(skill.memory_scopes),
      "knowledge_scopes" => list_to_input(skill.knowledge_scopes),
      "trigger_conditions" => json_input(skill.trigger_conditions),
      "evals" => json_input(skill.evals),
      "provenance" => json_input(skill.provenance)
    }
  end

  defp attrs_to_form(attrs) do
    empty_skill_form_attrs()
    |> Map.merge(attrs)
    |> Map.update("required_tools", "", &list_to_input/1)
    |> Map.update("memory_scopes", "", &list_to_input/1)
    |> Map.update("knowledge_scopes", "", &list_to_input/1)
    |> Map.update("trigger_conditions", "{}", &json_input/1)
    |> Map.update("evals", "{}", &json_input/1)
    |> Map.update("provenance", "{}", &json_input/1)
  end

  defp list_to_input(values) when is_list(values), do: Enum.join(values, ", ")
  defp list_to_input(value), do: to_string(value || "")

  defp json_input(value) when value in [%{}, nil], do: "{}"
  defp json_input(value) when is_map(value), do: Jason.encode!(value)
  defp json_input(value), do: to_string(value || "{}")

  defp parse_skill_form_attrs(attrs) do
    attrs = stringify_keys(attrs)
    form_attrs = attrs_to_form(attrs)

    with {:ok, trigger_conditions} <-
           parse_json_map(:trigger_conditions, attrs["trigger_conditions"]),
         {:ok, evals} <- parse_json_map(:evals, attrs["evals"]),
         {:ok, provenance} <- parse_json_map(:provenance, attrs["provenance"]) do
      {:ok,
       %{
         "name" => attrs |> Map.get("name", "") |> String.trim(),
         "slug" => attrs |> Map.get("slug", "") |> String.trim(),
         "description" => attrs |> Map.get("description", "") |> String.trim(),
         "instructions" => attrs |> Map.get("instructions", "") |> String.trim(),
         "required_tools" => split_list(attrs["required_tools"]),
         "memory_scopes" => split_list(attrs["memory_scopes"]),
         "knowledge_scopes" => split_list(attrs["knowledge_scopes"]),
         "trigger_conditions" => trigger_conditions,
         "evals" => evals,
         "provenance" => provenance
       }}
    else
      {:error, field, message} ->
        {:error, form_attrs, %{field => [message]}}
    end
  end

  defp parse_json_map(field, value) do
    value = String.trim(to_string(value || "{}"))

    case Jason.decode(if(value == "", do: "{}", else: value)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _value} -> {:error, field, "must be a JSON object"}
      {:error, _error} -> {:error, field, "must be valid JSON"}
    end
  end

  defp split_list(value) do
    value
    |> to_string()
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp empty_usage_summary do
    %{
      "records" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "by_category" => %{}
    }
  end

  defp usage_summary(%{owner_agent_id: nil}), do: empty_usage_summary()

  defp usage_summary(skill) do
    Usage.summarize(skill.workspace_id, agent_id: skill.owner_agent_id)
  end

  defp eval_suite(skill) do
    suite_ref =
      get_in(skill.evals || %{}, ["suite_id"]) || get_in(skill.evals || %{}, [:suite_id])

    case suite_ref do
      nil ->
        nil

      ref when is_integer(ref) ->
        Enum.find(Evals.list_suites(skill.workspace_id), &(&1.id == ref))

      ref when is_binary(ref) ->
        Enum.find(Evals.list_suites(skill.workspace_id), fn suite ->
          suite.slug == ref or suite.name == ref or to_string(suite.id) == ref
        end)
    end
  end

  defp eval_reports(skill) do
    case eval_suite(skill) do
      nil ->
        []

      suite ->
        skill.workspace_id
        |> Evals.list_runs(agent_id: skill.owner_agent_id, suite_id: suite.id, limit: 4)
        |> Enum.map(&Evals.report/1)
    end
  end

  defp category_count(summary, category), do: get_in(summary, ["by_category", category]) || 0

  defp readiness_items(skill, eval_suite, eval_reports) do
    [
      readiness_item(
        "Instructions",
        String.trim(to_string(skill.instructions || "")) != "",
        "instructions are present",
        "instructions are missing"
      ),
      readiness_item(
        "Owner",
        not is_nil(skill.owner_agent_id),
        "owner agent assigned",
        "owner agent is unassigned"
      ),
      eval_suite_readiness(skill, eval_suite),
      eval_run_readiness(skill, eval_suite, eval_reports),
      readiness_item(
        "Version history",
        Skills.list_versions(skill) != [],
        "version snapshots are recorded",
        "no version snapshot recorded"
      )
    ]
  end

  defp readiness_state(items) do
    if Enum.all?(items, &(&1.level == :ok)), do: "ready", else: "needs review"
  end

  defp readiness_item(label, true, ok, _warn), do: %{label: label, level: :ok, text: ok}
  defp readiness_item(label, false, _ok, warn), do: %{label: label, level: :warn, text: warn}

  defp eval_suite_readiness(skill, nil) do
    suite_ref =
      get_in(skill.evals || %{}, ["suite_id"]) || get_in(skill.evals || %{}, [:suite_id])

    if suite_ref do
      %{label: "Eval suite", level: :warn, text: "attached eval suite was not found"}
    else
      %{label: "Eval suite", level: :warn, text: "no eval suite attached"}
    end
  end

  defp eval_suite_readiness(_skill, suite) do
    %{label: "Eval suite", level: :ok, text: "attached to #{suite.slug}"}
  end

  defp eval_run_readiness(_skill, nil, _reports) do
    %{label: "Eval result", level: :warn, text: "no eval run evidence"}
  end

  defp eval_run_readiness(_skill, _suite, []) do
    %{label: "Eval result", level: :warn, text: "attached suite has no eval runs"}
  end

  defp eval_run_readiness(skill, _suite, [report | _reports]) do
    pass_rate = get_in(report, ["quality", "pass_rate"]) || 0.0
    threshold = eval_threshold(skill)

    cond do
      is_number(threshold) and pass_rate >= threshold ->
        %{
          label: "Eval result",
          level: :ok,
          text: "#{percent(pass_rate)} pass rate meets #{percent(threshold)} threshold"
        }

      is_number(threshold) ->
        %{
          label: "Eval result",
          level: :warn,
          text: "#{percent(pass_rate)} pass rate is below #{percent(threshold)} threshold"
        }

      pass_rate >= 1.0 ->
        %{label: "Eval result", level: :ok, text: "#{percent(pass_rate)} latest pass rate"}

      true ->
        %{label: "Eval result", level: :warn, text: "#{percent(pass_rate)} latest pass rate"}
    end
  end

  defp activation_override_visible?(skill, eval_reports) do
    threshold = eval_threshold(skill)
    pass_rate = eval_reports |> List.first() |> then(&get_in(&1 || %{}, ["quality", "pass_rate"]))

    is_number(threshold) and (is_nil(pass_rate) or pass_rate < threshold)
  end

  defp eval_threshold(skill) do
    case get_in(skill.evals || %{}, ["threshold"]) || get_in(skill.evals || %{}, [:threshold]) do
      value when is_float(value) or is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value)
      _value -> nil
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _error -> nil
    end
  end

  defp failure_label(failure) do
    failure["case_slug"] || "case #{failure["eval_case_id"]}"
  end

  defp eval_comparisons(reports) do
    reports
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [current, previous] ->
      %{
        current_id: current["eval_run_id"],
        previous_id: previous["eval_run_id"],
        pass_rate_delta:
          rate_delta(
            get_in(current, ["quality", "pass_rate"]),
            get_in(previous, ["quality", "pass_rate"])
          ),
        average_score_delta:
          rate_delta(
            get_in(current, ["quality", "average_score"]),
            get_in(previous, ["quality", "average_score"])
          ),
        failed_delta:
          count_delta(
            get_in(current, ["summary", "failed"]),
            get_in(previous, ["summary", "failed"])
          ),
        errored_delta:
          count_delta(
            get_in(current, ["summary", "errored"]),
            get_in(previous, ["summary", "errored"])
          )
      }
    end)
  end

  defp rate_delta(current, previous) when is_number(current) and is_number(previous),
    do: current - previous

  defp rate_delta(_current, _previous), do: nil

  defp count_delta(current, previous) when is_integer(current) and is_integer(previous),
    do: current - previous

  defp count_delta(_current, _previous), do: nil

  defp signed_percent(nil), do: "n/a"

  defp signed_percent(value) when is_number(value) do
    sign = if value > 0, do: "+", else: ""
    "#{sign}#{Float.round(value * 100, 1)}%"
  end

  defp signed_count(nil), do: "n/a"

  defp signed_count(value) when is_integer(value) do
    sign = if value > 0, do: "+", else: ""
    "#{sign}#{value}"
  end

  defp activation_overrides(skill) do
    case get_in(skill.provenance || %{}, ["activation_overrides"]) do
      overrides when is_list(overrides) -> overrides
      _overrides -> []
    end
  end

  defp version_changes(version, versions) do
    case Enum.find(versions, &(&1.version == version.version - 1)) do
      nil ->
        ["initial snapshot"]

      previous ->
        version.snapshot
        |> Map.keys()
        |> Enum.concat(Map.keys(previous.snapshot || %{}))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.filter(fn key ->
          Map.get(version.snapshot || %{}, key) != Map.get(previous.snapshot || %{}, key)
        end)
        |> Enum.map(&friendly_field/1)
        |> case do
          [] -> ["no captured field changes"]
          changes -> changes
        end
    end
  end

  defp friendly_field("owner_agent_id"), do: "owner"
  defp friendly_field("source_run_id"), do: "source run"
  defp friendly_field("trigger_conditions"), do: "trigger conditions"
  defp friendly_field("required_tools"), do: "required tools"
  defp friendly_field("memory_scopes"), do: "memory scopes"
  defp friendly_field("knowledge_scopes"), do: "knowledge scopes"
  defp friendly_field("activated_at"), do: "activation timestamp"
  defp friendly_field("deprecated_at"), do: "deprecation timestamp"
  defp friendly_field(field), do: String.replace(to_string(field), "_", " ")

  defp percent(nil), do: "n/a"
  defp percent(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp percent(value), do: to_string(value)

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="skill-detail" class="space-y-8">
      <ControlShell.header
        active={:skills}
        description={@skill.description}
        eyebrow="Skill detail"
        title={@skill.name}
        workspace_id={@workspace_id}
        workspace_switcher={false}
      >
        <:actions>
          <.link
            navigate={~p"/control/skills?workspace_id=#{@workspace_id}"}
            class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Skills Registry
          </.link>
        </:actions>
      </ControlShell.header>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Status</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{@skill.status}</p>
          <p class="mt-1 text-sm text-zinc-600">slug {@skill.slug}</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Owner</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">
            {(@owner_agent && @owner_agent.name) || "unassigned"}
          </p>
          <p class="mt-1 text-sm text-zinc-600">{(@owner_agent && @owner_agent.role) || "n/a"}</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Source</p>
          <p class="mt-3 truncate text-2xl font-semibold text-zinc-950">
            {(@source_run && @source_run.title) || "manual"}
          </p>
          <.link
            :if={@source_run}
            navigate={~p"/control/runs/#{@source_run.id}"}
            class="mt-1 inline-flex text-sm font-semibold text-zinc-950 underline decoration-zinc-300 underline-offset-2 hover:decoration-zinc-950"
          >
            Open timeline
          </.link>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Lifecycle</p>
          <p class="mt-3 text-sm text-zinc-600">activated {timestamp(@skill.activated_at)}</p>
          <p class="mt-1 text-sm text-zinc-600">deprecated {timestamp(@skill.deprecated_at)}</p>
        </div>
      </div>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Usage</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{@usage_summary["total_tokens"]}</p>
          <p class="mt-1 text-sm text-zinc-600">{@usage_summary["records"]} owner-agent records</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Chat</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">
            {category_count(@usage_summary, "chat")}
          </p>
          <p class="mt-1 text-sm text-zinc-600">conversation usage records</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Eval Usage</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">
            {category_count(@usage_summary, "eval")}
          </p>
          <p class="mt-1 text-sm text-zinc-600">eval usage records</p>
        </div>
        <div class="rounded-lg border border-zinc-200 bg-white p-4">
          <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Eval Runs</p>
          <p class="mt-3 text-2xl font-semibold text-zinc-950">{length(@eval_reports)}</p>
          <p class="mt-1 text-sm text-zinc-600">
            {(@eval_suite && @eval_suite.slug) || "no attached suite"}
          </p>
        </div>
      </div>

      <section class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-lg font-semibold text-zinc-950">Activation Readiness</h2>
          <span class="rounded-md border border-zinc-200 bg-white px-2 py-1 text-xs font-semibold uppercase text-zinc-600">
            {readiness_state(readiness_items(@skill, @eval_suite, @eval_reports))}
          </span>
        </div>
        <div id="skill-detail-readiness" class="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
          <div
            :for={item <- readiness_items(@skill, @eval_suite, @eval_reports)}
            class={[
              "rounded-lg border bg-white p-4",
              item.level == :ok && "border-emerald-200",
              item.level != :ok && "border-amber-200"
            ]}
          >
            <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
              {item.label}
            </p>
            <p class={[
              "mt-2 text-sm font-semibold",
              item.level == :ok && "text-emerald-700",
              item.level != :ok && "text-amber-700"
            ]}>
              {if item.level == :ok, do: "ready", else: "review"}
            </p>
            <p class="mt-1 text-sm text-zinc-600">{item.text}</p>
          </div>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold text-zinc-950">Lifecycle Controls</h2>
        <div class="flex flex-wrap gap-2 rounded-lg border border-zinc-200 bg-white p-4">
          <button
            id="skill-detail-test"
            type="button"
            phx-click="test-skill"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Test
          </button>
          <button
            id="skill-detail-edit"
            type="button"
            phx-click="edit-skill"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
          >
            Edit
          </button>
          <button
            id="skill-detail-activate"
            type="button"
            phx-click="activate-skill"
            class="rounded-md border border-emerald-200 px-3 py-2 text-sm font-medium text-emerald-700 transition hover:border-emerald-400"
          >
            Activate
          </button>
          <button
            id="skill-detail-deprecate"
            type="button"
            phx-click="deprecate-skill"
            class="rounded-md border border-amber-200 px-3 py-2 text-sm font-medium text-amber-700 transition hover:border-amber-400"
          >
            Deprecate
          </button>
          <button
            id="skill-detail-archive"
            type="button"
            phx-click="archive-skill"
            class="rounded-md border border-red-200 px-3 py-2 text-sm font-medium text-red-700 transition hover:border-red-400"
          >
            Archive
          </button>
        </div>
        <form
          :if={activation_override_visible?(@skill, @eval_reports)}
          id="skill-detail-override-activation-form"
          phx-submit="override-activate-skill"
          class="mt-4 grid gap-2 rounded-md border border-amber-200 bg-amber-50 p-3 md:grid-cols-[1fr_auto]"
        >
          <input
            id="skill-detail-override-reason"
            name="override[override_reason]"
            type="text"
            placeholder="Override reason"
            class="rounded-md border border-amber-200 px-3 py-2 text-sm text-amber-950 placeholder:text-amber-700 focus:border-amber-400 focus:outline-none"
          />
          <button
            id="skill-detail-override-activate"
            type="submit"
            class="rounded-md border border-amber-300 bg-white px-3 py-2 text-sm font-medium text-amber-800 transition hover:border-amber-500"
          >
            Override Activate
          </button>
          <p class="text-xs text-amber-800 md:col-span-2">
            Records an operator override in skill provenance when eval evidence is below the declared activation threshold.
          </p>
        </form>
      </section>

      <section :if={@editing_skill} class="space-y-3">
        <h2 class="text-lg font-semibold text-zinc-950">Edit Skill</h2>
        <form
          id="skill-detail-form"
          phx-submit="save-skill"
          class="grid gap-4 rounded-lg border border-zinc-200 bg-white p-4 lg:grid-cols-2"
        >
          <div>
            <label
              for="skill-detail-name"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Name
            </label>
            <input
              id="skill-detail-name"
              name="skill[name]"
              value={@skill_form_attrs["name"]}
              type="text"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
            />
            <p
              :for={error <- Map.get(@skill_form_errors, :name, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div>
            <label
              for="skill-detail-slug"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Slug
            </label>
            <input
              id="skill-detail-slug"
              name="skill[slug]"
              value={@skill_form_attrs["slug"]}
              type="text"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
            />
            <p
              :for={error <- Map.get(@skill_form_errors, :slug, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div class="lg:col-span-2">
            <label
              for="skill-detail-description"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Description
            </label>
            <textarea
              id="skill-detail-description"
              name="skill[description]"
              rows="2"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
            ><%= @skill_form_attrs["description"] %></textarea>
            <p
              :for={error <- Map.get(@skill_form_errors, :description, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div class="lg:col-span-2">
            <label
              for="skill-detail-form-instructions"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Instructions
            </label>
            <textarea
              id="skill-detail-form-instructions"
              name="skill[instructions]"
              rows="7"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
            ><%= @skill_form_attrs["instructions"] %></textarea>
            <p
              :for={error <- Map.get(@skill_form_errors, :instructions, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div>
            <label
              for="skill-detail-required-tools"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Required Tools
            </label>
            <input
              id="skill-detail-required-tools"
              name="skill[required_tools]"
              value={@skill_form_attrs["required_tools"]}
              type="text"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
            />
            <p
              :for={error <- Map.get(@skill_form_errors, :required_tools, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div>
            <label
              for="skill-detail-memory-scopes"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Memory Scopes
            </label>
            <input
              id="skill-detail-memory-scopes"
              name="skill[memory_scopes]"
              value={@skill_form_attrs["memory_scopes"]}
              type="text"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
            />
          </div>

          <div>
            <label
              for="skill-detail-knowledge-scopes"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Knowledge Scopes
            </label>
            <input
              id="skill-detail-knowledge-scopes"
              name="skill[knowledge_scopes]"
              value={@skill_form_attrs["knowledge_scopes"]}
              type="text"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
            />
          </div>

          <div>
            <label
              for="skill-detail-trigger-conditions"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Trigger Conditions JSON
            </label>
            <textarea
              id="skill-detail-trigger-conditions"
              name="skill[trigger_conditions]"
              rows="4"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 font-mono text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
            ><%= @skill_form_attrs["trigger_conditions"] %></textarea>
            <p
              :for={error <- Map.get(@skill_form_errors, :trigger_conditions, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div>
            <label
              for="skill-detail-evals-json"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Eval Metadata JSON
            </label>
            <textarea
              id="skill-detail-evals-json"
              name="skill[evals]"
              rows="4"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 font-mono text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
            ><%= @skill_form_attrs["evals"] %></textarea>
            <p
              :for={error <- Map.get(@skill_form_errors, :evals, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div class="lg:col-span-2">
            <label
              for="skill-detail-provenance-json"
              class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
            >
              Provenance JSON
            </label>
            <textarea
              id="skill-detail-provenance-json"
              name="skill[provenance]"
              rows="4"
              class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 font-mono text-xs text-zinc-700 focus:border-zinc-400 focus:outline-none"
            ><%= @skill_form_attrs["provenance"] %></textarea>
            <p
              :for={error <- Map.get(@skill_form_errors, :provenance, [])}
              class="mt-1 text-xs text-red-700"
            >
              {error}
            </p>
          </div>

          <div class="flex flex-wrap gap-2 lg:col-span-2">
            <button
              id="skill-detail-save"
              type="submit"
              class="rounded-md border border-zinc-950 bg-zinc-950 px-3 py-2 text-sm font-medium text-white transition hover:bg-zinc-800"
            >
              Save Draft
            </button>
            <button
              id="skill-detail-cancel-edit"
              type="button"
              phx-click="cancel-edit-skill"
              class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
            >
              Cancel
            </button>
          </div>
        </form>
      </section>

      <div class="grid gap-6 xl:grid-cols-[1.1fr_0.9fr]">
        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Instructions</h2>
          <div id="skill-detail-instructions" class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="whitespace-pre-wrap text-sm leading-6 text-zinc-700">{@skill.instructions}</p>
          </div>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Permissions</h2>
          <div id="skill-detail-permissions" class="space-y-2">
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">Required Tools</p>
              <p class="mt-2 text-sm text-zinc-600">
                {join_or_none(@skill.required_tools || [])}
              </p>
            </div>
            <div class="rounded-lg border border-zinc-200 bg-white p-4">
              <p class="text-sm font-semibold text-zinc-950">Scopes</p>
              <p class="mt-2 text-sm text-zinc-600">
                memory {join_or_none(@skill.memory_scopes || [])}
              </p>
              <p class="mt-1 text-sm text-zinc-600">
                knowledge {join_or_none(@skill.knowledge_scopes || [])}
              </p>
            </div>
          </div>
        </section>
      </div>

      <div class="grid gap-6 xl:grid-cols-3">
        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Trigger Conditions</h2>
          <pre
            id="skill-detail-triggers"
            class="overflow-auto rounded-lg border border-zinc-200 bg-white p-4 text-xs leading-5 text-zinc-700"
          ><%= compact_json(@skill.trigger_conditions) %></pre>
        </section>
        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Eval Metadata</h2>
          <pre
            id="skill-detail-evals"
            class="overflow-auto rounded-lg border border-zinc-200 bg-white p-4 text-xs leading-5 text-zinc-700"
          ><%= compact_json(@skill.evals) %></pre>
        </section>
        <section class="space-y-3">
          <h2 class="text-lg font-semibold text-zinc-950">Provenance</h2>
          <pre
            id="skill-detail-provenance"
            class="overflow-auto rounded-lg border border-zinc-200 bg-white p-4 text-xs leading-5 text-zinc-700"
          ><%= compact_json(@skill.provenance) %></pre>
        </section>
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold text-zinc-950">Eval Reports</h2>
        <div
          id="skill-detail-eval-comparisons"
          class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-4 md:grid-cols-2"
        >
          <div class="md:col-span-2">
            <p class="text-sm font-semibold text-zinc-950">Eval Comparison</p>
            <p class="mt-1 text-sm text-zinc-600">
              Latest runs compared against the immediately preceding run for this skill's owner and suite.
            </p>
          </div>
          <div
            :for={comparison <- eval_comparisons(@eval_reports)}
            id={"skill-detail-eval-comparison-#{comparison.current_id}-#{comparison.previous_id}"}
            class="rounded-md border border-zinc-100 bg-zinc-50 p-3"
          >
            <p class="text-sm font-semibold text-zinc-950">
              Run {comparison.current_id} vs {comparison.previous_id}
            </p>
            <div class="mt-2 grid gap-2 text-sm text-zinc-600 md:grid-cols-2">
              <p>pass rate {signed_percent(comparison.pass_rate_delta)}</p>
              <p>average {signed_percent(comparison.average_score_delta)}</p>
              <p>failed {signed_count(comparison.failed_delta)}</p>
              <p>errored {signed_count(comparison.errored_delta)}</p>
            </div>
          </div>
          <p :if={eval_comparisons(@eval_reports) == []} class="text-sm text-zinc-500">
            At least two eval runs are needed for comparison.
          </p>
        </div>
        <div id="skill-detail-eval-reports" class="grid gap-3 md:grid-cols-2">
          <div
            :for={report <- @eval_reports}
            id={"skill-detail-eval-report-#{report["eval_run_id"]}"}
            class="rounded-lg border border-zinc-200 bg-white p-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="text-sm font-semibold text-zinc-950">Run #{report["eval_run_id"]}</p>
                <p class="mt-1 text-sm text-zinc-600">{report["status"]}</p>
              </div>
              <span class="text-xs font-semibold uppercase text-zinc-500">
                {percent(get_in(report, ["quality", "pass_rate"]))}
              </span>
            </div>
            <p class="mt-3 text-sm text-zinc-600">
              passed {get_in(report, ["summary", "passed"])} / failed {get_in(report, [
                "summary",
                "failed"
              ])} / errored {get_in(report, ["summary", "errored"])}
            </p>
            <p class="mt-1 text-xs text-zinc-500">
              average {percent(get_in(report, ["quality", "average_score"]))} / duration {get_in(
                report,
                ["timing", "duration_ms"]
              ) || "n/a"}ms
            </p>
            <div
              :if={report["failures"] != []}
              id={"skill-detail-eval-report-#{report["eval_run_id"]}-failures"}
              class="mt-3 space-y-2 border-t border-zinc-100 pt-3"
            >
              <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                Failures
              </p>
              <div
                :for={failure <- report["failures"]}
                class="rounded-md border border-red-100 bg-red-50 p-2"
              >
                <p class="text-xs font-semibold text-red-900">
                  {failure_label(failure)} / {failure["status"]}
                </p>
                <p class="mt-1 text-xs text-red-800">
                  score {failure["score"] || "n/a"} / {compact_json(failure["error"] || %{})}
                </p>
              </div>
            </div>
          </div>
          <div
            :if={@eval_reports == []}
            class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
          >
            No eval runs found for this skill's attached suite and owner agent.
          </div>
        </div>
      </section>

      <section :if={activation_overrides(@skill) != []} class="space-y-3">
        <h2 class="text-lg font-semibold text-zinc-950">Activation Overrides</h2>
        <div id="skill-detail-activation-overrides" class="grid gap-3 md:grid-cols-2">
          <article
            :for={override <- activation_overrides(@skill)}
            class="rounded-lg border border-amber-200 bg-amber-50 p-4"
          >
            <p class="text-sm font-semibold text-amber-950">
              {override["reason"] || "operator override"}
            </p>
            <p class="mt-1 text-sm text-amber-800">
              actor {override["actor"] || "operator"} / {override["overridden_at"] || "unknown time"}
            </p>
          </article>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold text-zinc-950">Version History</h2>
        <div id="skill-detail-version-history" class="space-y-3">
          <article
            :for={version <- @skill_versions}
            id={"skill-detail-version-#{version.version}"}
            class="rounded-lg border border-zinc-200 bg-white p-4"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p class="text-sm font-semibold text-zinc-950">
                  Version {version.version} / {version.change_kind}
                </p>
                <p class="mt-1 text-sm text-zinc-600">
                  {version.status} / recorded {timestamp(version.inserted_at)}
                </p>
              </div>
              <span class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-semibold text-zinc-600">
                {length(version.snapshot["required_tools"] || [])} tools
              </span>
            </div>
            <p class="mt-3 line-clamp-2 text-sm text-zinc-600">
              {version.snapshot["description"] || "no description captured"}
            </p>
            <div class="mt-3 border-t border-zinc-100 pt-3">
              <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                Changes
              </p>
              <p class="mt-1 text-sm text-zinc-600">
                {Enum.join(version_changes(version, @skill_versions), ", ")}
              </p>
            </div>
          </article>
          <div
            :if={@skill_versions == []}
            class="rounded-lg border border-zinc-200 bg-white p-4 text-sm text-zinc-500"
          >
            No skill versions have been recorded yet.
          </div>
        </div>
      </section>
    </section>
    """
  end
end
