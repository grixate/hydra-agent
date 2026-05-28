defmodule HydraAgentWeb.AutomationLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{Automations, Connectors, Runtime}
  alias HydraAgent.Automations.Automation
  alias HydraAgentWeb.ControlShell

  @statuses ["all", "needs_attention" | Automation.statuses()]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Automations")
     |> assign(:workspace_id, nil)
     |> assign(:status, "all")
     |> assign(:statuses, @statuses)
     |> assign(:form_mode, :create)
     |> assign(:editing_automation_id, nil)
     |> assign(:form_attrs, empty_form_attrs())
     |> assign(:form_errors, %{})
     |> assign(:schedule_preview, [])
     |> assign(:recipes, Automations.recipes())
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
  def handle_event("filter-automations", params, socket) do
    params = stringify_keys(params)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/control/automations?workspace_id=#{socket.assigns.workspace_id}&status=#{status_param(params["status"])}"
     )}
  end

  def handle_event("new-automation", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_mode, :create)
     |> assign(:editing_automation_id, nil)
     |> assign(:form_attrs, default_form_attrs(socket.assigns))
     |> assign(:form_errors, %{})
     |> assign(:schedule_preview, schedule_preview(default_form_attrs(socket.assigns)))}
  end

  def handle_event("edit-automation", %{"id" => id}, socket) do
    automation = automation(id)
    attrs = automation_form_attrs(automation)

    {:noreply,
     socket
     |> assign(:form_mode, :edit)
     |> assign(:editing_automation_id, automation.id)
     |> assign(:form_attrs, attrs)
     |> assign(:form_errors, %{})
     |> assign(:schedule_preview, schedule_preview(attrs))}
  end

  def handle_event("cancel-automation-form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_mode, :create)
     |> assign(:editing_automation_id, nil)
     |> assign(:form_attrs, default_form_attrs(socket.assigns))
     |> assign(:form_errors, %{})
     |> assign(:schedule_preview, schedule_preview(default_form_attrs(socket.assigns)))}
  end

  def handle_event("validate-automation", %{"automation" => attrs}, socket) do
    attrs = normalize_form_attrs(attrs)

    {:noreply,
     socket
     |> assign(:form_attrs, attrs)
     |> assign(:schedule_preview, schedule_preview(attrs))}
  end

  def handle_event("save-automation", %{"automation" => attrs}, socket) do
    attrs =
      attrs
      |> normalize_form_attrs()
      |> Map.put("workspace_id", socket.assigns.workspace_id)

    result =
      case socket.assigns.form_mode do
        :edit ->
          socket.assigns.editing_automation_id
          |> automation()
          |> Automations.update_automation(attrs)

        :create ->
          Automations.create_automation(attrs)
      end

    case result do
      {:ok, _automation} ->
        message =
          if socket.assigns.form_mode == :edit,
            do: "Automation updated",
            else: "Automation created"

        next_attrs = default_form_attrs(socket.assigns)

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(:form_mode, :create)
         |> assign(:editing_automation_id, nil)
         |> assign(:form_attrs, next_attrs)
         |> assign(:form_errors, %{})
         |> assign(:schedule_preview, schedule_preview(next_attrs))
         |> load_workspace_state()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form_attrs, attrs)
         |> assign(:form_errors, changeset_errors(changeset))
         |> assign(:schedule_preview, schedule_preview(attrs))}
    end
  end

  def handle_event("create-from-recipe", %{"recipe" => params}, socket) do
    params = stringify_keys(params)

    result =
      Automations.create_from_recipe(socket.assigns.workspace_id, params["recipe_id"], %{
        "agent_id" => params["agent_id"],
        "room_id" => params["room_id"],
        "timezone" => params["timezone"] || "Etc/UTC",
        "permission_preset" => params["permission_preset"] || "approve_writes"
      })

    case result do
      {:ok, _automation} ->
        {:noreply,
         socket |> put_flash(:info, "Recipe automation created") |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Recipe could not be created: #{inspect(error)}")}
    end
  end

  def handle_event("pause-automation", %{"id" => id}, socket) do
    id
    |> automation()
    |> Automations.update_automation(%{"status" => "paused"})
    |> handle_automation_result(socket, "Automation paused")
  end

  def handle_event("resume-automation", %{"id" => id}, socket) do
    id
    |> automation()
    |> Automations.update_automation(%{"status" => "active"})
    |> handle_automation_result(socket, "Automation resumed")
  end

  def handle_event("archive-automation", %{"id" => id}, socket) do
    id
    |> automation()
    |> Automations.update_automation(%{"status" => "archived"})
    |> handle_automation_result(socket, "Automation archived")
  end

  def handle_event("run-automation", %{"id" => id}, socket) do
    id
    |> automation()
    |> Automations.run_automation()
    |> handle_automation_result(socket, "Automation triggered")
  end

  def handle_event("clear-automation-error", %{"id" => id}, socket) do
    id
    |> automation()
    |> Automations.clear_last_error()
    |> handle_automation_result(socket, "Automation error cleared")
  end

  defp load_workspaces(socket) do
    assign(socket, :workspaces, Runtime.list_workspaces())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:automations, [])
    |> assign(:automation_counts, %{})
    |> assign(:agents, [])
    |> assign(:agents_by_id, %{})
    |> assign(:policies_by_agent, %{})
    |> assign(:workspace_policies, [])
    |> assign(:automation_histories, %{})
    |> assign(:automation_run_histories, %{})
    |> assign(:automation_run_stats, %{})
    |> assign(:automation_readiness_by_id, %{})
    |> assign(:now, now())
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id, status: status}} = socket) do
    all_automations = Automations.list_automations(workspace_id)
    connector_accounts = Connectors.list_accounts(workspace_id)
    automation_readiness_by_id = automation_readiness_by_id(all_automations, connector_accounts)
    agents = Runtime.list_agents(workspace_id)
    tool_policies = Runtime.list_tool_policies(workspace_id)
    conversations = Runtime.list_conversations(workspace_id)
    runs = Runtime.list_runs(workspace_id)

    automations = filter_automations(all_automations, status, automation_readiness_by_id)

    agents_by_id = Map.new(agents, &{&1.id, &1})
    socket = ensure_form_defaults(socket, agents)

    socket
    |> assign(:automations, automations)
    |> assign(:automation_counts, status_counts(all_automations))
    |> assign(:agents, agents)
    |> assign(:agents_by_id, agents_by_id)
    |> assign(:policies_by_agent, policies_by_agent(tool_policies))
    |> assign(:workspace_policies, Enum.filter(tool_policies, &is_nil(&1.agent_id)))
    |> assign(:automation_histories, automation_histories(all_automations, conversations))
    |> assign(:automation_run_histories, automation_run_histories(all_automations, runs))
    |> assign(:automation_run_stats, automation_run_stats(all_automations, runs))
    |> assign(:automation_readiness_by_id, automation_readiness_by_id)
    |> assign(:now, now())
  end

  defp handle_automation_result({:ok, _automation}, socket, message) do
    {:noreply, socket |> put_flash(:info, message) |> load_workspace_state()}
  end

  defp handle_automation_result({:error, changeset}, socket, _message) do
    {:noreply,
     put_flash(socket, :error, "Automation update failed: #{inspect(changeset.errors)}")}
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

  defp automation(id), do: id |> parse_id() |> Automations.get_automation!()

  defp status_param(status) when status in @statuses, do: status
  defp status_param(_status), do: "all"

  defp status_counts(automations), do: Enum.frequencies_by(automations, & &1.status)

  defp filter_automations(automations, "all", _readiness_by_id), do: automations

  defp filter_automations(automations, "needs_attention", readiness_by_id),
    do: Enum.filter(automations, &needs_attention?(&1, readiness_by_id))

  defp filter_automations(automations, status, _readiness_by_id),
    do: Enum.filter(automations, &(&1.status == status))

  defp attention_count(automations, readiness_by_id),
    do: Enum.count(automations, &needs_attention?(&1, readiness_by_id))

  defp due_count(automations, now) do
    Enum.count(automations, fn automation ->
      (automation.status == "active" and automation.next_run_at) &&
        DateTime.compare(automation.next_run_at, now) != :gt
    end)
  end

  defp agent_name(agent_id, agents_by_id) do
    case Map.get(agents_by_id, agent_id) do
      nil -> "agent #{agent_id}"
      agent -> agent.name
    end
  end

  defp timestamp(nil), do: "n/a"
  defp timestamp(datetime), do: Calendar.strftime(datetime, "%m-%d %H:%M")

  defp policies_by_agent(policies) do
    policies
    |> Enum.reject(&is_nil(&1.agent_id))
    |> Enum.group_by(& &1.agent_id)
  end

  defp matching_policies(automation, policies_by_agent, workspace_policies) do
    Map.get(policies_by_agent, automation.agent_id, []) ++ workspace_policies
  end

  defp policy_summary([]), do: "no matching tool policy"

  defp policy_summary(policies) do
    approval =
      if Enum.any?(policies, & &1.requires_approval),
        do: "approval gated",
        else: "no approval gate"

    classes =
      policies
      |> Enum.flat_map(&(&1.side_effect_classes || []))
      |> Enum.uniq()
      |> Enum.sort()
      |> join_or_none()

    "#{length(policies)} policies / #{approval} / #{classes}"
  end

  defp automation_histories(automations, conversations) do
    automation_ids = MapSet.new(automations, &to_string(&1.id))

    conversations
    |> Enum.filter(fn conversation ->
      to_string(conversation.metadata["automation_id"]) in automation_ids
    end)
    |> Enum.group_by(&to_string(&1.metadata["automation_id"]))
    |> Map.new(fn {automation_id, records} ->
      {String.to_integer(automation_id), Enum.take(records, 3)}
    end)
  end

  defp history_for(automation, histories), do: Map.get(histories, automation.id, [])

  defp automation_run_histories(automations, runs) do
    automation_ids = MapSet.new(automations, &to_string(&1.id))

    runs
    |> Enum.filter(fn run ->
      to_string(metadata_value(run, "automation_id")) in automation_ids
    end)
    |> Enum.group_by(&to_string(metadata_value(&1, "automation_id")))
    |> Map.new(fn {automation_id, records} ->
      {String.to_integer(automation_id), Enum.take(records, 3)}
    end)
  end

  defp automation_run_stats(automations, runs) do
    automation_ids = MapSet.new(automations, &to_string(&1.id))

    histories =
      runs
      |> Enum.filter(fn run ->
        to_string(metadata_value(run, "automation_id")) in automation_ids
      end)
      |> Enum.group_by(&to_string(metadata_value(&1, "automation_id")))
      |> Map.new(fn {automation_id, records} ->
        {String.to_integer(automation_id), records}
      end)

    Map.new(automations, fn automation ->
      runs = Map.get(histories, automation.id, [])

      {automation.id,
       %{
         total: length(runs),
         completed: Enum.count(runs, &(&1.status == "completed")),
         failed: Enum.count(runs, &(&1.status == "failed")),
         last_duration_ms: runs |> List.first() |> run_duration_ms()
       }}
    end)
  end

  defp run_duration_ms(nil), do: nil

  defp run_duration_ms(run) do
    case {run.started_at, run.completed_at} do
      {%DateTime{} = started_at, %DateTime{} = completed_at} ->
        DateTime.diff(completed_at, started_at, :millisecond)

      _timestamps ->
        nil
    end
  end

  defp automation_stats(automation, stats), do: Map.get(stats, automation.id, %{})

  defp duration(nil), do: "n/a"
  defp duration(ms), do: "#{ms}ms"

  defp metadata_value(%{metadata: metadata}, key) when is_map(metadata),
    do: metadata[to_string(key)] || metadata[key]

  defp metadata_value(_record, _key), do: nil

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp error_summary(error) when error in [%{}, nil], do: "none"

  defp error_summary(error) when is_map(error) do
    error
    |> Jason.encode!()
    |> String.slice(0, 180)
  end

  defp error_reason(error) when is_map(error), do: error["reason"] || error[:reason] || "error"
  defp error_reason(_error), do: "error"

  defp error_message(error) when is_map(error), do: error["message"] || error[:message]
  defp error_message(_error), do: nil

  defp compact_json(map) when map in [%{}, nil], do: "{}"

  defp compact_json(map) when is_map(map) do
    map
    |> Jason.encode!()
    |> String.slice(0, 520)
  end

  defp error?(%{last_error: error}), do: error?(error)
  defp error?(error) when error in [%{}, nil], do: false
  defp error?(_error), do: true

  defp automation_readiness_by_id(automations, connector_accounts) do
    Map.new(automations, fn automation ->
      {automation.id, Automations.readiness(automation, connector_accounts)}
    end)
  end

  defp automation_readiness(automation, readiness_by_id) do
    Map.get(readiness_by_id, automation.id, %{
      "status" => "ready",
      "required_connectors" => [],
      "checks" => [],
      "blockers" => [],
      "warnings" => []
    })
  end

  defp readiness_issues(%{"blockers" => blockers, "warnings" => warnings}),
    do: blockers ++ warnings

  defp readiness_issues(_readiness), do: []

  defp needs_attention?(automation, readiness_by_id) do
    error?(automation) or
      automation_readiness(automation, readiness_by_id)["status"] in [
        "blocked",
        "setup_pending"
      ]
  end

  defp readiness_class("ready"), do: "text-emerald-700"
  defp readiness_class("setup_pending"), do: "text-amber-700"
  defp readiness_class(_status), do: "text-red-700"

  defp readiness_issue_class(%{"severity" => "warning"}), do: "text-amber-700"
  defp readiness_issue_class(_issue), do: "text-red-700"

  defp readiness_issue_text(%{"provider" => provider, "reason" => "connector_missing"}) do
    "#{provider}: connector account is missing"
  end

  defp readiness_issue_text(%{"provider" => provider, "findings" => findings} = issue)
       when is_list(findings) and findings != [] do
    "#{provider}: #{Enum.map_join(findings, "; ", &readiness_finding_text/1)}"
    |> maybe_append_issue_reason(issue)
  end

  defp readiness_issue_text(%{"provider" => provider, "reason" => reason}) do
    "#{provider}: #{reason}"
  end

  defp readiness_issue_text(issue), do: inspect(issue)

  defp readiness_finding_text(%{"reason" => reason, "fields" => fields}) when is_list(fields) do
    "#{reason} (#{Enum.join(fields, ", ")})"
  end

  defp readiness_finding_text(%{"reason" => reason}), do: reason
  defp readiness_finding_text(finding), do: inspect(finding)

  defp maybe_append_issue_reason(text, %{"reason" => reason})
       when reason in ["connector_needs_attention", "connector_setup_pending"],
       do: text

  defp maybe_append_issue_reason(text, %{"reason" => reason}), do: "#{text} / #{reason}"
  defp maybe_append_issue_reason(text, _issue), do: text

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp empty_form_attrs do
    %{
      "agent_id" => "",
      "name" => "",
      "slug" => "",
      "status" => "active",
      "cron_expression" => "0 9 * * *",
      "timezone" => "Etc/UTC",
      "prompt" => ""
    }
  end

  defp default_form_attrs(assigns) do
    empty_form_attrs()
    |> Map.put("agent_id", default_agent_id(Map.get(assigns, :agents, [])))
  end

  defp ensure_form_defaults(socket, agents) do
    case socket.assigns.form_attrs do
      %{"agent_id" => ""} = attrs ->
        attrs = Map.put(attrs, "agent_id", default_agent_id(agents))

        socket
        |> assign(:form_attrs, attrs)
        |> assign(:schedule_preview, schedule_preview(attrs))

      _attrs ->
        socket
    end
  end

  defp default_agent_id([]), do: ""
  defp default_agent_id([agent | _agents]), do: to_string(agent.id)

  defp automation_form_attrs(automation) do
    %{
      "agent_id" => to_string(automation.agent_id),
      "name" => automation.name || "",
      "slug" => automation.slug || "",
      "status" => automation.status || "active",
      "cron_expression" => automation.cron_expression || "",
      "timezone" => automation.timezone || "Etc/UTC",
      "prompt" => automation.prompt || ""
    }
  end

  defp normalize_form_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> Map.take(~w(agent_id name slug status cron_expression timezone prompt))
    |> Map.update("name", "", &String.trim/1)
    |> Map.update("slug", "", &String.trim/1)
    |> Map.update("cron_expression", "", &String.trim/1)
    |> Map.update("timezone", "Etc/UTC", fn
      "" -> "Etc/UTC"
      timezone -> String.trim(timezone)
    end)
    |> Map.update("prompt", "", &String.trim/1)
  end

  defp schedule_preview(%{"cron_expression" => expression, "timezone" => timezone}) do
    expression = String.trim(to_string(expression || ""))
    timezone = timezone || "Etc/UTC"

    cond do
      !timezone_supported?(timezone) ->
        [%{label: "unsupported timezone", at: nil, timezone: timezone}]

      true ->
        case next_runs(expression, now(), timezone, 5) do
          [] -> [%{label: "invalid cron", at: nil, timezone: timezone}]
          runs -> Enum.with_index(runs, 1) |> Enum.map(&preview_run(&1, timezone))
        end
    end
  end

  defp schedule_preview(_attrs), do: []

  defp preview_run({run_at, index}, timezone) do
    local_at =
      case DateTime.shift_zone(run_at, timezone) do
        {:ok, datetime} -> datetime
        {:error, _reason} -> run_at
      end

    %{
      label: "#{index}. #{timestamp(local_at)}",
      utc_label: "UTC #{timestamp(run_at)}",
      at: run_at,
      timezone: timezone
    }
  end

  defp timezone_supported?(timezone) do
    match?({:ok, _datetime}, DateTime.now(timezone))
  end

  defp next_runs("", _from, _timezone, _count), do: []

  defp next_runs(_expression, _from, _timezone, 0), do: []

  defp next_runs(expression, from, timezone, count) do
    case Automations.next_run_at(expression, from, timezone) do
      nil ->
        []

      next_run ->
        [
          next_run
          | next_runs(expression, DateTime.add(next_run, 1, :second), timezone, count - 1)
        ]
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  @impl true
  def render(assigns) do
    ~H"""
    <section id="automations" class="space-y-8">
      <ControlShell.header
        active={:automations}
        description="Monitor scheduled prompts, agent routing, next and last runs, errors, and operator-triggered execution."
        eyebrow="Operations"
        query={%{status: @status}}
        title="Automations"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <section class="rounded-lg border border-zinc-200 bg-white p-5">
          <div class="flex items-start justify-between gap-4">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                Recipe Catalog
              </p>
              <h2 class="mt-2 text-lg font-semibold text-zinc-950">Ready-made automations</h2>
            </div>
            <span class="rounded-md bg-zinc-100 px-2 py-1 text-xs font-medium text-zinc-600">
              {length(@recipes)}
            </span>
          </div>

          <div id="automation-recipes" class="mt-4 grid gap-3 xl:grid-cols-2">
            <article
              :for={recipe <- @recipes}
              id={"automation-recipe-#{recipe["id"]}"}
              class="rounded-lg border border-zinc-200 p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-zinc-950">{recipe["name"]}</p>
                  <p class="mt-1 line-clamp-2 text-sm text-zinc-600">{recipe["prompt"]}</p>
                </div>
                <span class="text-xs font-medium uppercase text-zinc-500">
                  {recipe["cron_expression"]}
                </span>
              </div>
              <p class="mt-2 text-xs text-zinc-500">
                connectors {join_or_none(recipe["required_connectors"] || [])}
              </p>
              <.form
                for={%{}}
                as={:recipe}
                phx-submit="create-from-recipe"
                class="mt-3 grid gap-2 md:grid-cols-[1fr_110px]"
              >
                <input type="hidden" name="recipe[recipe_id]" value={recipe["id"]} />
                <select name="recipe[agent_id]" class="rounded-md border-zinc-300 text-sm">
                  <option value="">Select agent</option>
                  <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
                </select>
                <button
                  type="submit"
                  class="rounded-md bg-zinc-950 px-3 py-2 text-xs font-semibold text-white"
                >
                  Create
                </button>
              </.form>
            </article>
          </div>
        </section>

        <section class="rounded-lg border border-zinc-200 bg-white p-5">
          <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                {if @form_mode == :edit, do: "Edit Schedule", else: "Create Schedule"}
              </p>
              <h2 class="mt-2 text-lg font-semibold text-zinc-950">
                {if @form_mode == :edit, do: "Update automation", else: "New automation"}
              </h2>
            </div>
            <button
              :if={@form_mode == :edit}
              id="automation-new"
              type="button"
              phx-click="new-automation"
              class="rounded-md border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
            >
              New
            </button>
          </div>

          <form
            id="automation-form"
            phx-change="validate-automation"
            phx-submit="save-automation"
            class="mt-4 grid gap-4 lg:grid-cols-[1fr_0.8fr]"
          >
            <div class="grid gap-3 md:grid-cols-2">
              <div>
                <label
                  for="automation-name"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Name
                </label>
                <input
                  id="automation-name"
                  name="automation[name]"
                  value={@form_attrs["name"]}
                  type="text"
                  class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
                />
                <p :for={error <- Map.get(@form_errors, :name, [])} class="mt-1 text-xs text-red-700">
                  {error}
                </p>
              </div>

              <div>
                <label
                  for="automation-slug"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Slug
                </label>
                <input
                  id="automation-slug"
                  name="automation[slug]"
                  value={@form_attrs["slug"]}
                  type="text"
                  class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
                />
                <p :for={error <- Map.get(@form_errors, :slug, [])} class="mt-1 text-xs text-red-700">
                  {error}
                </p>
              </div>

              <div>
                <label
                  for="automation-agent"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Agent
                </label>
                <select
                  id="automation-agent"
                  name="automation[agent_id]"
                  class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
                >
                  <option value="">select agent</option>
                  <option
                    :for={agent <- @agents}
                    value={agent.id}
                    selected={to_string(agent.id) == to_string(@form_attrs["agent_id"])}
                  >
                    {agent.name}
                  </option>
                </select>
                <p
                  :for={error <- Map.get(@form_errors, :agent_id, [])}
                  class="mt-1 text-xs text-red-700"
                >
                  {error}
                </p>
              </div>

              <div>
                <label
                  for="automation-status"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Status
                </label>
                <select
                  id="automation-status"
                  name="automation[status]"
                  class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
                >
                  <option
                    :for={status <- Automation.statuses()}
                    value={status}
                    selected={status == @form_attrs["status"]}
                  >
                    {status}
                  </option>
                </select>
              </div>

              <div>
                <label
                  for="automation-cron"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Cron
                </label>
                <input
                  id="automation-cron"
                  name="automation[cron_expression]"
                  value={@form_attrs["cron_expression"]}
                  type="text"
                  class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
                />
                <p
                  :for={error <- Map.get(@form_errors, :cron_expression, [])}
                  class="mt-1 text-xs text-red-700"
                >
                  {error}
                </p>
              </div>

              <div>
                <label
                  for="automation-timezone"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Timezone
                </label>
                <input
                  id="automation-timezone"
                  name="automation[timezone]"
                  value={@form_attrs["timezone"]}
                  type="text"
                  class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
                />
                <p
                  :for={error <- Map.get(@form_errors, :timezone, [])}
                  class="mt-1 text-xs text-red-700"
                >
                  {error}
                </p>
              </div>

              <div class="md:col-span-2">
                <label
                  for="automation-prompt"
                  class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500"
                >
                  Prompt
                </label>
                <textarea
                  id="automation-prompt"
                  name="automation[prompt]"
                  rows="4"
                  class="mt-1 w-full rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
                ><%= @form_attrs["prompt"] %></textarea>
                <p
                  :for={error <- Map.get(@form_errors, :prompt, [])}
                  class="mt-1 text-xs text-red-700"
                >
                  {error}
                </p>
              </div>
            </div>

            <div class="rounded-lg border border-zinc-100 bg-zinc-50 p-4">
              <p class="text-sm font-semibold text-zinc-950">Schedule Preview</p>
              <p class="mt-1 text-xs text-zinc-500">Next five matching runs</p>
              <div id="automation-schedule-preview" class="mt-3 space-y-2">
                <div
                  :for={preview <- @schedule_preview}
                  class="rounded-md border border-zinc-200 bg-white px-3 py-2"
                >
                  <p class="text-sm text-zinc-700">{preview.label} / {preview.timezone}</p>
                  <p :if={preview[:utc_label]} class="mt-1 text-xs text-zinc-500">
                    {preview.utc_label}
                  </p>
                </div>
              </div>
              <p class="mt-3 text-xs leading-5 text-zinc-500">
                Cron expressions are evaluated in the selected timezone when the configured timezone database supports it.
              </p>
              <div class="mt-4 flex flex-wrap gap-2">
                <button
                  id="automation-save"
                  type="submit"
                  class="rounded-md border border-zinc-950 bg-zinc-950 px-3 py-2 text-sm font-medium text-white transition hover:bg-zinc-800"
                >
                  {if @form_mode == :edit, do: "Update", else: "Create"}
                </button>
                <button
                  id="automation-cancel"
                  type="button"
                  phx-click="cancel-automation-form"
                  class="rounded-md border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-zinc-400"
                >
                  Cancel
                </button>
              </div>
            </div>
          </form>
        </section>

        <form
          id="automations-filter-form"
          phx-change="filter-automations"
          class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-4 md:grid-cols-[220px_1fr]"
        >
          <select
            id="automations-filter-status"
            name="status"
            class="rounded-md border border-zinc-200 px-3 py-2 text-sm text-zinc-700 focus:border-zinc-400 focus:outline-none"
          >
            <option :for={status <- @statuses} value={status} selected={status == @status}>
              {status}
            </option>
          </select>
          <p class="flex items-center text-sm text-zinc-500">
            {length(@automations)} visible / {Enum.sum(Map.values(@automation_counts))} total automations
          </p>
        </form>

        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Attention</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {attention_count(@automations, @automation_readiness_by_id)}
            </p>
            <p class="mt-1 text-sm text-zinc-600">visible schedules with errors or blockers</p>
          </div>
          <div
            :for={status <- Automation.statuses()}
            id={"automations-count-#{status}"}
            class="rounded-lg border border-zinc-200 bg-white p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">{status}</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {Map.get(@automation_counts, status, 0)}
            </p>
          </div>
          <div class="rounded-lg border border-zinc-200 bg-white p-4">
            <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">Due</p>
            <p class="mt-3 text-3xl font-semibold text-zinc-950">
              {due_count(@automations, @now)}
            </p>
            <p class="mt-1 text-sm text-zinc-600">visible active schedules</p>
          </div>
        </div>

        <div id="automations-list" class="grid gap-4 xl:grid-cols-2">
          <article
            :for={automation <- @automations}
            id={"automation-card-#{automation.id}"}
            class="rounded-lg border border-zinc-200 bg-white p-5"
          >
            <% readiness = automation_readiness(automation, @automation_readiness_by_id) %>
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <p class="truncate text-lg font-semibold text-zinc-950">{automation.name}</p>
                <p class="mt-1 text-sm text-zinc-600">
                  {automation.status} / {agent_name(automation.agent_id, @agents_by_id)}
                </p>
              </div>
              <span class="text-xs font-medium uppercase text-zinc-500">
                {automation.cron_expression}
              </span>
            </div>

            <p class="mt-3 line-clamp-2 text-sm text-zinc-600">{automation.prompt}</p>

            <div class="mt-4 grid gap-3 text-sm text-zinc-600 md:grid-cols-2">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">Next</p>
                <p class="mt-1">{timestamp(automation.next_run_at)} / {automation.timezone}</p>
              </div>
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">Last</p>
                <p class="mt-1">{timestamp(automation.last_run_at)}</p>
              </div>
              <div class="md:col-span-2">
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Last Error
                </p>
                <p class="mt-1 break-words">{error_summary(automation.last_error)}</p>
              </div>
              <div
                id={"automation-readiness-#{automation.id}"}
                class="md:col-span-2 rounded-md border border-zinc-100 bg-zinc-50 p-3"
              >
                <div class="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                      Connector Readiness
                    </p>
                    <p class="mt-1 text-sm text-zinc-600">
                      requires {join_or_none(readiness["required_connectors"])}
                    </p>
                  </div>
                  <p class={["text-sm font-semibold", readiness_class(readiness["status"])]}>
                    {readiness["status"]}
                  </p>
                </div>
                <p
                  :for={issue <- readiness_issues(readiness)}
                  class={["mt-2 text-sm font-medium", readiness_issue_class(issue)]}
                >
                  {readiness_issue_text(issue)}
                </p>
              </div>
              <div
                :if={error?(automation)}
                id={"automation-error-detail-#{automation.id}"}
                class="md:col-span-2 rounded-md border border-red-100 bg-red-50 p-3"
              >
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-red-700">
                  Failure Detail
                </p>
                <p class="mt-2 text-sm font-medium text-red-900">
                  {error_reason(automation.last_error)}
                </p>
                <p :if={error_message(automation.last_error)} class="mt-1 text-sm text-red-800">
                  {error_message(automation.last_error)}
                </p>
                <p class="mt-2 break-words font-mono text-xs text-red-800">
                  {compact_json(automation.last_error)}
                </p>
              </div>
              <div
                :if={
                  metadata_value(automation, "last_conversation_id") ||
                    metadata_value(automation, "last_assistant_turn_id") ||
                    metadata_value(automation, "last_run_id")
                }
                id={"automation-last-output-#{automation.id}"}
                class="md:col-span-2 rounded-md border border-zinc-100 bg-zinc-50 p-3"
              >
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Last Output
                </p>
                <p class="mt-1 text-sm text-zinc-600">
                  run {metadata_value(automation, "last_run_id") || "n/a"} / conversation {metadata_value(
                    automation,
                    "last_conversation_id"
                  ) || "n/a"} / assistant turn {metadata_value(
                    automation,
                    "last_assistant_turn_id"
                  ) || "n/a"}
                </p>
              </div>
              <div
                id={"automation-run-analytics-#{automation.id}"}
                class="md:col-span-2 rounded-md border border-zinc-100 bg-zinc-50 p-3"
              >
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Execution Analytics
                </p>
                <div class="mt-2 grid gap-2 text-sm text-zinc-600 md:grid-cols-4">
                  <p>runs {automation_stats(automation, @automation_run_stats).total || 0}</p>
                  <p>
                    completed {automation_stats(automation, @automation_run_stats).completed || 0}
                  </p>
                  <p>failed {automation_stats(automation, @automation_run_stats).failed || 0}</p>
                  <p>
                    last duration {duration(
                      automation_stats(automation, @automation_run_stats).last_duration_ms
                    )}
                  </p>
                </div>
              </div>
              <div class="md:col-span-2">
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Safety Policy
                </p>
                <p class="mt-1">
                  {policy_summary(
                    matching_policies(automation, @policies_by_agent, @workspace_policies)
                  )}
                </p>
              </div>
              <div class="md:col-span-2">
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Recent Runs
                </p>
                <div id={"automation-history-#{automation.id}"} class="mt-1 space-y-1">
                  <div
                    :for={conversation <- history_for(automation, @automation_histories)}
                    id={"automation-history-item-#{automation.id}-#{conversation.id}"}
                    class="rounded-md border border-zinc-100 bg-zinc-50 p-2"
                  >
                    <p class="text-sm text-zinc-700">
                      {conversation.title || "Automation run"} / {conversation.status} / {timestamp(
                        conversation.last_message_at || conversation.updated_at
                      )}
                    </p>
                    <p class="mt-1 text-xs text-zinc-500">
                      conversation {conversation.id} / {conversation.channel}
                    </p>
                    <p class="mt-1 break-words font-mono text-xs text-zinc-500">
                      {compact_json(conversation.metadata)}
                    </p>
                  </div>
                  <p
                    :if={history_for(automation, @automation_histories) == []}
                    class="text-sm text-zinc-600"
                  >
                    no runs yet
                  </p>
                </div>
              </div>
              <div class="md:col-span-2">
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Runtime Runs
                </p>
                <div id={"automation-run-history-#{automation.id}"} class="mt-1 space-y-1">
                  <div
                    :for={run <- history_for(automation, @automation_run_histories)}
                    id={"automation-run-history-item-#{automation.id}-#{run.id}"}
                    class="rounded-md border border-zinc-100 bg-zinc-50 p-2"
                  >
                    <div class="flex flex-wrap items-center justify-between gap-2">
                      <p class="text-sm text-zinc-700">
                        {run.title} / {run.status} / {timestamp(run.completed_at || run.updated_at)}
                      </p>
                      <.link
                        navigate={~p"/control/runs/#{run.id}"}
                        class="text-xs font-semibold text-zinc-950 underline decoration-zinc-300 underline-offset-2 hover:decoration-zinc-950"
                      >
                        Open run
                      </.link>
                    </div>
                    <p class="mt-1 break-words font-mono text-xs text-zinc-500">
                      {compact_json(run.metadata)}
                    </p>
                  </div>
                  <p
                    :if={history_for(automation, @automation_run_histories) == []}
                    class="text-sm text-zinc-600"
                  >
                    no runtime runs yet
                  </p>
                </div>
              </div>
            </div>

            <div class="mt-4 flex flex-wrap gap-2 border-t border-zinc-100 pt-4">
              <button
                id={"automation-edit-#{automation.id}"}
                type="button"
                phx-click="edit-automation"
                phx-value-id={automation.id}
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Edit
              </button>
              <button
                id={"automation-run-#{automation.id}"}
                type="button"
                phx-click="run-automation"
                phx-value-id={automation.id}
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Trigger
              </button>
              <button
                :if={error?(automation)}
                id={"automation-clear-error-#{automation.id}"}
                type="button"
                phx-click="clear-automation-error"
                phx-value-id={automation.id}
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700 transition hover:border-zinc-400"
              >
                Clear Error
              </button>
              <button
                id={"automation-pause-#{automation.id}"}
                type="button"
                phx-click="pause-automation"
                phx-value-id={automation.id}
                class="rounded-md border border-amber-200 px-2 py-1 text-xs font-medium text-amber-700 transition hover:border-amber-400"
              >
                Pause
              </button>
              <button
                id={"automation-resume-#{automation.id}"}
                type="button"
                phx-click="resume-automation"
                phx-value-id={automation.id}
                class="rounded-md border border-emerald-200 px-2 py-1 text-xs font-medium text-emerald-700 transition hover:border-emerald-400"
              >
                Resume
              </button>
              <button
                id={"automation-archive-#{automation.id}"}
                type="button"
                phx-click="archive-automation"
                phx-value-id={automation.id}
                class="rounded-md border border-red-200 px-2 py-1 text-xs font-medium text-red-700 transition hover:border-red-400"
              >
                Archive
              </button>
            </div>
          </article>

          <div
            :if={@automations == []}
            class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500"
          >
            No automations match this filter.
          </div>
        </div>
      <% else %>
        <div class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </div>
      <% end %>
    </section>
    """
  end
end
