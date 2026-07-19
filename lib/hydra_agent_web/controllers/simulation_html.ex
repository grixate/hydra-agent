defmodule HydraAgentWeb.SimulationHTML do
  use HydraAgentWeb, :html

  alias HydraAgentWeb.SimulationCopy

  embed_templates "simulation_html/*"

  attr :simulation, :any, required: true
  attr :workspace, :any, required: true
  attr :locale, :string, required: true
  attr :routes, :list, required: true
  attr :source_report, :any, default: nil

  def report_form(assigns) do
    ~H"""
    <form
      :if={@routes != []}
      action={"/simulations/#{@simulation.id}/results/reports?workspace_id=#{@workspace.id}&locale=#{@locale}"}
      method="post"
      class="simulation-report-form"
    >
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <input
        :if={@source_report}
        type="hidden"
        name="report[source_report_id]"
        value={@source_report.id}
      />
      <label>
        <span>{t(@locale, :report_language)}</span>
        <select name="report[locale]">
          <option value="en" selected={@locale == "en"}>{t(@locale, :report_language_en)}</option>
          <option value="ru" selected={@locale == "ru"}>{t(@locale, :report_language_ru)}</option>
        </select>
      </label>
      <label>
        <span>{t(@locale, :report_audience)}</span>
        <select name="report[audience]">
          <option value="general">{t(@locale, :report_audience_general)}</option>
          <option value="executive">{t(@locale, :report_audience_executive)}</option>
          <option value="technical">{t(@locale, :report_audience_technical)}</option>
        </select>
      </label>
      <label>
        <span>{t(@locale, :report_length)}</span>
        <select name="report[length]">
          <option value="concise">{t(@locale, :report_length_concise)}</option>
          <option value="standard" selected>{t(@locale, :report_length_standard)}</option>
          <option value="detailed">{t(@locale, :report_length_detailed)}</option>
        </select>
      </label>
      <label>
        <span>{t(@locale, :report_model)}</span>
        <select name="report[provider_config_id]">
          <option :for={route <- @routes} value={route["id"]}>
            {provider_option_label(route)}
          </option>
        </select>
      </label>
      <button type="submit">
        {if @source_report,
          do: t(@locale, :report_regenerate_action),
          else: t(@locale, :report_generate)}
      </button>
      <small>{t(@locale, :report_no_rerun)}</small>
    </form>
    <p :if={@routes == []} class="simulation-report-route-missing">
      {t(@locale, :report_route_unavailable)}
    </p>
    """
  end

  def t(locale, key), do: SimulationCopy.t(locale, key)
  def tx(locale, key, values), do: SimulationCopy.interpolate(locale, key, values)

  def report_reference_count(locale, count),
    do: SimulationCopy.report_reference_count(locale, count)

  def localized(value, locale) when is_map(value) do
    value[locale] || value["en"] || "Blueprint"
  end

  def status_key("archived"), do: :archived_status
  def status_key(status), do: String.to_existing_atom(status)

  def workbench_status_key(:run, _simulation, nil, {:ok, _summary}), do: :ready_to_run

  def workbench_status_key(:run, _simulation, %{run: %{status: status}}, _readiness)
      when status in ~w(planned running),
      do: :running

  def workbench_status_key(:run, _simulation, %{run: %{status: "completed"}}, _readiness),
    do: :ready

  def workbench_status_key(:run, _simulation, %{run: %{status: "canceled"}}, _readiness),
    do: :canceled

  def workbench_status_key(:run, _simulation, %{run: %{status: "failed"}}, _readiness),
    do: :failed

  def workbench_status_key(_stage, simulation, _latest_run, _readiness),
    do: status_key(simulation.status)

  def stage_status_key("running"), do: :running_stage
  def stage_status_key("failed"), do: :failed_stage
  def stage_status_key(status), do: String.to_existing_atom(status)

  def format_date(%DateTime{} = datetime, "ru"), do: Calendar.strftime(datetime, "%d.%m.%Y")
  def format_date(%NaiveDateTime{} = datetime, "ru"), do: Calendar.strftime(datetime, "%d.%m.%Y")
  def format_date(%DateTime{} = datetime, _locale), do: Calendar.strftime(datetime, "%b %d, %Y")

  def format_date(%NaiveDateTime{} = datetime, _locale),
    do: Calendar.strftime(datetime, "%b %d, %Y")

  def index_path(workspace_id, locale) do
    "/simulations?" <>
      URI.encode_query(%{"workspace_id" => workspace_id || "", "locale" => locale})
  end

  def new_path(workspace_id, locale) do
    "/simulations/new?" <>
      URI.encode_query(%{"workspace_id" => workspace_id || "", "locale" => locale})
  end

  def stage_path(simulation_id, stage, workspace_id, locale) do
    "/simulations/#{simulation_id}/#{stage}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def stage_locale_path(
        simulation_id,
        stage,
        workspace_id,
        locale,
        latest_run,
        selected_comparison
      ) do
    params = %{"workspace_id" => workspace_id, "locale" => locale}

    params =
      if stage in ~w(results compare) and latest_run,
        do: Map.put(params, "run_id", latest_run.id),
        else: params

    params =
      if stage == "compare" and selected_comparison,
        do: Map.put(params, "compare_run_id", selected_comparison.id),
        else: params

    "/simulations/#{simulation_id}/#{stage}?" <> URI.encode_query(params)
  end

  def script_export_path(simulation_id, format, workspace_id, locale) do
    "/simulations/#{simulation_id}/script/export/#{format}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def result_export_path(simulation_id, artifact, workspace_id, locale) do
    "/simulations/#{simulation_id}/results/export/#{artifact}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def simulation_pack_export_path(simulation_id),
    do: "/simulations/#{simulation_id}/export/simpack"

  def manual_request_path(simulation_id, workspace_id, locale) do
    "/simulations/#{simulation_id}/manual-request.json?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def manual_import_path(simulation_id), do: "/simulations/#{simulation_id}/manual-import"

  def run_pack_export_path(simulation_id, run_id),
    do: "/simulations/#{simulation_id}/results/runs/#{run_id}/export/run-pack"

  def run_diagnostics_path(simulation_id, run_id, workspace_id, locale) do
    "/simulations/#{simulation_id}/runs/#{run_id}/diagnostics.json?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def report_export_path(simulation_id, report_id, format, workspace_id, locale) do
    "/simulations/#{simulation_id}/results/reports/#{report_id}/export/#{format}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def blueprint_path(blueprint, workspace_id, locale) do
    action = if blueprint.built_in, do: "", else: "/edit"

    "/blueprints/#{blueprint.id}#{action}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)

  def input_labels(inputs, locale) do
    labels = []
    labels = if inputs["notes"], do: [t(locale, :notes_added) | labels], else: labels

    labels =
      case length(inputs["urls"] || []) do
        0 -> labels
        count -> [tx(locale, :url_count, count: count) | labels]
      end

    labels =
      case length(inputs["files"] || []) do
        0 -> labels
        count -> [tx(locale, :file_count, count: count) | labels]
      end

    Enum.reverse(labels)
  end

  def mode_label(mode), do: String.to_existing_atom(mode)

  def run_lineage_key("exact_replay"), do: :run_exact_replay_label
  def run_lineage_key("fresh_rerun"), do: :run_fresh_rerun_label
  def run_lineage_key(_kind), do: :run_original

  def cognition_source_key("model"), do: :cognition_source_model
  def cognition_source_key("exact_replay"), do: :cognition_source_replay

  def cognition_source_key(source)
      when source in ~w(exact_cache policy_signature_cache representative_decision),
      do: :cognition_source_cache

  def cognition_source_key(_source), do: :cognition_source_rule

  def cognition_agents_label(count, "ru") when is_integer(count) do
    "#{count} #{russian_plural(count, "агент", "агента", "агентов")}"
  end

  def cognition_agents_label(1, _locale), do: "1 agent"
  def cognition_agents_label(count, _locale), do: "#{count} agents"

  def run_status_key("planned"), do: :run_queued_status
  def run_status_key("running"), do: :run_running_status
  def run_status_key("completed"), do: :run_completed_status
  def run_status_key("failed"), do: :run_failed_status
  def run_status_key("canceled"), do: :run_canceled_status
  def run_status_key(_status), do: :run_queued_status

  def run_heading_key(nil, {:ok, _summary}), do: :run_ready
  def run_heading_key(nil, _readiness), do: :not_ready_to_run

  def run_heading_key(%{run: %{status: status}}, _readiness) when status in ~w(planned running),
    do: :run_active_title

  def run_heading_key(%{run: %{status: "completed"}}, _readiness), do: :run_complete_title
  def run_heading_key(%{run: %{status: "canceled"}}, _readiness), do: :run_canceled_title
  def run_heading_key(_run, _readiness), do: :run_failed_title

  def run_lede_key(nil, {:ok, _summary}), do: :run_ready_lede
  def run_lede_key(nil, _readiness), do: :not_ready_to_run_lede

  def run_lede_key(%{run: %{status: status}}, _readiness) when status in ~w(planned running),
    do: :run_active_lede

  def run_lede_key(%{run: %{status: "completed"}}, _readiness), do: :run_complete_lede
  def run_lede_key(%{run: %{status: "canceled"}}, _readiness), do: :run_canceled_lede
  def run_lede_key(_run, _readiness), do: :run_failed_lede

  def run_active?(%{run: %{status: status}}), do: status in ~w(planned running)
  def run_active?(_run), do: false

  def run_progress(%{rounds_planned: rounds, current_round: current}) when rounds > 0,
    do: "#{current} / #{rounds}"

  def run_progress(_run), do: "—"

  def run_seal_text(%{run: %{status: status}} = run) when status in ~w(planned running),
    do: "#{run.current_round}/#{run.rounds_planned}"

  def run_seal_text(%{run: %{status: "completed"}}), do: "✓"
  def run_seal_text(%{run: %{status: "canceled"}}), do: "×"
  def run_seal_text(%{run: %{status: "failed"}}), do: "!"
  def run_seal_text(_run), do: "◇"

  def run_seal_label(locale, %{run: %{status: status}} = run, _readiness)
      when status in ~w(planned running),
      do: "#{t(locale, :run_progress)} #{run_progress(run)}"

  def run_seal_label(locale, %{run: %{status: status}}, _readiness),
    do: t(locale, run_status_key(status))

  def run_seal_label(locale, nil, {:ok, _summary}), do: t(locale, :run_ready)
  def run_seal_label(locale, _run, _readiness), do: t(locale, :not_ready_to_run)

  def budget_cost_label(locale, %{hard_cost_cap: nil}), do: t(locale, :budget_cost_unknown)

  def budget_cost_label(_locale, %{hard_cost_cap: cost, currency: currency}) do
    amount = cost |> Decimal.round(2) |> Decimal.to_string(:normal)
    "#{currency} #{amount}"
  end

  def budget_cost_label(locale, _plan), do: t(locale, :budget_cost_unknown)

  def budget_estimate_label(
        _locale,
        %{
          pricing_status: "known",
          currency: currency,
          estimates: %{"minimum_cost" => minimum, "maximum_cost" => maximum}
        }
      )
      when is_binary(minimum) and is_binary(maximum),
      do: "#{money_label(currency, minimum)}–#{money_label(currency, maximum)}"

  def budget_estimate_label(locale, _plan), do: t(locale, :budget_estimate_unknown)

  def budget_cost_progress_label(
        locale,
        %{pricing_status: "known"},
        %{"currency" => currency, "used_cost" => used, "remaining_cost" => remaining}
      )
      when is_binary(used) and is_binary(remaining) do
    tx(locale, :budget_cost_progress,
      used: money_label(currency, used),
      remaining: money_label(currency, remaining)
    )
  end

  def budget_cost_progress_label(locale, _plan, _summary),
    do: t(locale, :budget_cost_unpriced_usage)

  def budget_decision_progress_label(locale, plan, summary) do
    cap = get_in(plan.stage_caps, ["simulation", "calls"]) || 0
    used = get_in(summary, ["by_stage", "simulation", "calls"]) || 0

    tx(locale, :budget_decision_progress,
      used: used,
      remaining: max(cap - used, 0)
    )
  end

  def budget_runtime_band_label(
        locale,
        %{estimates: %{"runtime_band_seconds" => %{"minimum" => minimum, "maximum" => maximum}}}
      )
      when is_integer(minimum) and is_integer(maximum),
      do: "#{duration_label(minimum, locale)}–#{duration_label(maximum, locale)}"

  def budget_runtime_band_label(locale, plan),
    do: runtime_label(plan.hard_runtime_seconds, locale)

  def budget_stage_label(locale, %{run: %{status: "planned"}}),
    do: t(locale, :budget_stage_queued)

  def budget_stage_label(locale, %{run: %{status: "running"}} = run),
    do: "#{t(locale, :budget_stage_simulation)} · #{run_progress(run)}"

  def budget_stage_label(locale, %{run: %{status: "completed"}}),
    do: t(locale, :budget_stage_complete)

  def budget_stage_label(locale, %{run: %{status: "canceled"}}),
    do: t(locale, :budget_stage_canceled)

  def budget_stage_label(locale, _run), do: t(locale, :budget_stage_stopped)

  def budget_preset_key(%{preset: preset}) when preset in ~w(quick balanced deep),
    do: String.to_existing_atom("budget_preset_#{preset}")

  def budget_preset_key(_plan), do: :budget_preset_quick

  def model_route_selection(%{selection: selection}, role), do: selection[role] || "automatic"
  def model_route_selection(_plan, _role), do: "automatic"

  def model_route_label(locale, %{"status" => "disabled"}), do: t(locale, :model_route_none)

  def model_route_label(locale, %{"status" => "unavailable"}),
    do: t(locale, :model_route_unavailable)

  def model_route_label(_locale, route) when is_map(route) do
    [route["name"], route["model"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def model_route_label(locale, _route), do: t(locale, :model_route_unavailable)

  def provider_option_label(provider) do
    [provider["name"], provider["model"], if(provider["local"], do: "Local")]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(" · ")
  end

  def robustness_key("available"), do: :analysis_robustness_available
  def robustness_key(_status), do: :analysis_robustness_insufficient

  def report_active?(%{status: status}), do: status in ~w(queued running)
  def report_active?(_report), do: false

  def report_status_key("ready"), do: :report_validated
  def report_status_key("failed"), do: :report_not_published
  def report_status_key(_status), do: :report_in_progress

  def report_audience_key("executive"), do: :report_audience_executive
  def report_audience_key("technical"), do: :report_audience_technical
  def report_audience_key(_audience), do: :report_audience_general

  def report_length_key("concise"), do: :report_length_concise
  def report_length_key("detailed"), do: :report_length_detailed
  def report_length_key(_length), do: :report_length_standard

  def report_usage_label(report, locale) do
    tokens = (report.actual_input_tokens || 0) + (report.actual_output_tokens || 0)

    case report.actual_cost do
      %Decimal{} = cost ->
        amount = cost |> Decimal.round(4) |> Decimal.to_string(:normal)

        tx(locale, :report_usage_cost,
          tokens: format_count(tokens, locale),
          cost: "#{report.currency} #{amount}"
        )

      _other ->
        tx(locale, :report_usage, tokens: format_count(tokens, locale))
    end
  end

  def analysis_metric_label(metric, locale),
    do: context_identifier(metric["id"] || metric["ref"], locale)

  def analysis_metric_value(%{"unit" => "fraction", "final" => value}, _locale)
      when is_number(value),
      do: "#{Float.round(value * 100, 1)}%"

  def analysis_metric_value(%{"final" => value}, locale) when is_integer(value),
    do: format_count(value, locale)

  def analysis_metric_value(%{"final" => value}, _locale) when is_float(value),
    do: value |> Float.round(3) |> :erlang.float_to_binary([:compact, decimals: 3])

  def analysis_metric_value(_metric, _locale), do: "—"

  def analysis_direction_key("increased"), do: :analysis_increased
  def analysis_direction_key("decreased"), do: :analysis_decreased
  def analysis_direction_key("stable"), do: :analysis_stable
  def analysis_direction_key(_direction), do: :analysis_observed

  def runtime_label(seconds, "ru") when is_integer(seconds), do: "до #{div(seconds, 60)} мин"

  def runtime_label(seconds, _locale) when is_integer(seconds),
    do: "up to #{div(seconds, 60)} min"

  def runtime_label(_seconds, _locale), do: "—"

  defp money_label(currency, value) do
    amount = value |> Decimal.new() |> Decimal.round(2) |> Decimal.to_string(:normal)
    "#{currency} #{amount}"
  end

  defp duration_label(seconds, "ru") when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} мин"
  defp duration_label(seconds, "ru"), do: "#{seconds} с"
  defp duration_label(seconds, _locale) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  defp duration_label(seconds, _locale), do: "#{seconds} sec"

  def grounding_key(class), do: String.to_existing_atom("context_grounding_#{class}")

  def context_source_status_key("pending"), do: :context_source_pending
  def context_source_status_key("review_required"), do: :context_source_review
  def context_source_status_key(_status), do: :context_source_active

  def context_research_status_key("queued"), do: :context_research_queued_status
  def context_research_status_key("running"), do: :context_research_running
  def context_research_status_key("completed"), do: :context_research_completed
  def context_research_status_key(_status), do: :context_research_failed

  def context_lane_status_key("complete"), do: :complete
  def context_lane_status_key("failed"), do: :failed_stage
  def context_lane_status_key(_status), do: :pending

  def context_gap_key(kind), do: String.to_existing_atom("context_gap_#{kind}")

  def percent(value) when is_number(value), do: "#{round(value * 100)}%"
  def percent(_value), do: "—"

  def context_pack_summary("ru", pack) do
    claims = length(pack.claims)
    assumptions = length(pack.assumptions)

    "Пакет v#{pack.version} · #{claims} #{russian_plural(claims, "утверждение", "утверждения", "утверждений")} · #{assumptions} #{russian_plural(assumptions, "допущение", "допущения", "допущений")}"
  end

  def context_pack_summary(_locale, pack) do
    claims = length(pack.claims)
    assumptions = length(pack.assumptions)

    "Context Pack v#{pack.version} · #{claims} #{english_plural(claims, "claim")} · #{assumptions} #{english_plural(assumptions, "assumption")}"
  end

  def confidence_label(locale, value) when is_number(value) do
    key =
      cond do
        value < 0.4 -> :context_confidence_low
        value < 0.7 -> :context_confidence_moderate
        true -> :context_confidence_high
      end

    t(locale, key)
  end

  def confidence_label(_locale, _value), do: "—"

  def context_identifier(identifier, "ru") do
    Map.get(
      %{
        "participant" => "Участник",
        "decision_maker" => "Лицо, принимающее решение",
        "influencer" => "Лидер мнений",
        "employee" => "Сотрудник",
        "manager" => "Руководитель",
        "informal_influencer" => "Неформальный лидер",
        "provider" => "Поставщик",
        "peer_influencer" => "Влиятельный участник",
        "time" => "Время",
        "information" => "Информация",
        "influence" => "Влияние",
        "trust" => "Доверие",
        "autonomy" => "Автономия",
        "budget" => "Бюджет",
        "influences" => "Влияет",
        "connected" => "Связан",
        "manages" => "Руководит",
        "trusts" => "Доверяет",
        "follows" => "Следует",
        "supplies" => "Снабжает",
        "competes" => "Конкурирует",
        "collaborates" => "Сотрудничает",
        "belongs_to" => "Принадлежит",
        "adopt" => "Принять",
        "delay" => "Отложить",
        "resist" => "Отказаться",
        "influence_others" => "Повлиять на других",
        "comply_reluctantly" => "Подчиниться без согласия",
        "change_introduced" => "Изменение объявлено",
        "information_clarity" => "Ясность информации",
        "current_round" => "Текущий раунд",
        "simulation_begins" => "Начало симуляции",
        "action_selected" => "Действие выбрано",
        "primary_action_rate" => "Доля основного действия"
      },
      identifier,
      localize_compound_identifier(identifier)
    )
  end

  def context_identifier(identifier, _locale), do: humanize_identifier(identifier)

  def source_host(%{"uri" => uri}) when is_binary(uri), do: URI.parse(uri).host
  def source_host(_source), do: nil

  def claim_source(%{"source_id" => source_id}, sources) when is_binary(source_id) do
    Enum.find(sources, &(&1["id"] == source_id))
  end

  def claim_source(_claim, _sources), do: nil

  def population_type_count(model, type_id) do
    get_in(model.compile_summary, ["type_counts", type_id]) || 0
  end

  def population_archetype_count(model, archetype_id) do
    get_in(model.compile_summary, ["archetype_counts", archetype_id]) || 0
  end

  def population_generated_count(model),
    do: model.compile_summary["generated_agent_count"] || 0

  def population_imported_count(model),
    do: model.compile_summary["imported_agent_count"] || 0

  def population_relationship_count(model),
    do: model.compile_summary["relationship_count"] || 0

  def population_representatives(model),
    do: model.compile_summary["representatives"] || []

  def population_representative_attributes(representative) do
    representative["attributes"]
    |> Kernel.||(%{})
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(4)
  end

  def population_relationship_groups(representative) do
    representative
    |> Map.get("important_relationships", [])
    |> Enum.map(& &1["type"])
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {type, _count} -> type end)
  end

  def persona_projection_for(projections, agent_id),
    do: Enum.find(projections, &(&1.agent_id == agent_id))

  def population_attribute_label(key, "ru") do
    Map.get(
      %{
        "openness" => "Готовность к изменениям",
        "risk_tolerance" => "Готовность к риску",
        "influence" => "Влияние",
        "information_access" => "Доступ к информации",
        "initial_stance" => "Начальная позиция",
        "imported_signal" => "Импортированный сигнал"
      },
      key,
      humanize_identifier(key)
    )
  end

  def population_attribute_label(key, _locale), do: humanize_identifier(key)

  def population_topology_label("small_world", "ru"), do: "Малый мир"
  def population_topology_label("hierarchical", "ru"), do: "Иерархическая"
  def population_topology_label("bipartite", "ru"), do: "Двудольная"
  def population_topology_label("random", "ru"), do: "Случайная"
  def population_topology_label("imported", "ru"), do: "Импортированная"
  def population_topology_label("none", "ru"), do: "Без связей"
  def population_topology_label(kind, _locale), do: humanize_identifier(kind)

  def format_count(value, "ru") when is_integer(value),
    do: value |> Integer.to_string() |> grouped_number(" ")

  def format_count(value, _locale) when is_integer(value),
    do: value |> Integer.to_string() |> grouped_number(",")

  def format_count(_value, _locale), do: "—"

  def population_import_summary(model, preview) do
    cond do
      is_map(preview) ->
        preview

      model && is_map(model.import_summary) && map_size(model.import_summary) > 0 ->
        model.import_summary

      true ->
        nil
    end
  end

  def population_import_error(locale, error) do
    key =
      case error["code"] do
        "invalid_identifier" ->
          :population_import_error_invalid_identifier

        "invalid_object" ->
          :population_import_error_invalid_object

        "sensitive_attribute_requires_model_metadata" ->
          :population_import_error_sensitive_attribute_requires_model_metadata

        "duplicate_identifier" ->
          :population_import_error_duplicate_identifier

        "invalid_weight" ->
          :population_import_error_invalid_weight

        "invalid_boolean" ->
          :population_import_error_invalid_boolean

        "self_relationship" ->
          :population_import_error_self_relationship

        _ ->
          :population_import_error_default
      end

    t(locale, key)
  end

  def population_trait_level(value, "ru") when is_number(value) and value < 0.34, do: "Низкий"

  def population_trait_level(value, "ru") when is_number(value) and value < 0.67,
    do: "Средний"

  def population_trait_level(value, "ru") when is_number(value), do: "Высокий"
  def population_trait_level(value, _locale) when is_number(value) and value < 0.34, do: "Low"

  def population_trait_level(value, _locale) when is_number(value) and value < 0.67,
    do: "Moderate"

  def population_trait_level(value, _locale) when is_number(value), do: "High"
  def population_trait_level(true, "ru"), do: "Да"
  def population_trait_level(false, "ru"), do: "Нет"
  def population_trait_level(true, _locale), do: "Yes"
  def population_trait_level(false, _locale), do: "No"

  def population_trait_level(value, "ru") when is_binary(value) do
    Map.get(
      %{
        "open" => "Открытая",
        "undecided" => "Неопределённая",
        "resistant" => "Сопротивляющаяся",
        "ready" => "Готово",
        "uncommitted" => "Без решения",
        "imported" => "Импортировано"
      },
      value,
      humanize_identifier(value)
    )
  end

  def population_trait_level(value, _locale) when is_binary(value), do: humanize_identifier(value)
  def population_trait_level(_value, _locale), do: "—"

  def script_preview_status_key(%{status: "passed"}), do: :script_preview_passed
  def script_preview_status_key(%{status: "failed"}), do: :script_preview_failed
  def script_preview_status_key(_preview), do: :script_preview_missing

  def script_preview_error(locale, %{"code" => code}) do
    key =
      case code do
        "insufficient_resource" -> :script_error_insufficient_resource
        "no_reachable_action" -> :script_error_no_reachable_action
        "missing_action" -> :script_error_missing_action
        "missing_policy" -> :script_error_missing_policy
        "no_preview_agents" -> :script_error_no_preview_agents
        "invalid_script" -> :script_error_invalid_script
        _other -> :script_error_default
      end

    t(locale, key)
  end

  def script_preview_error(locale, _error), do: t(locale, :script_error_default)

  def script_world_values(script) when is_map(script) do
    script
    |> get_in(["world", "state"])
    |> Kernel.||(%{})
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(6)
  end

  def script_world_values(_script), do: []

  def script_value(true, "ru"), do: "Да"
  def script_value(false, "ru"), do: "Нет"
  def script_value(true, _locale), do: "Yes"
  def script_value(false, _locale), do: "No"

  def script_value(value, _locale) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  def script_value(value, _locale) when is_integer(value), do: Integer.to_string(value)
  def script_value(value, locale) when is_binary(value), do: context_identifier(value, locale)
  def script_value(_value, _locale), do: "—"

  def script_clock_label(1, "week", "ru"), do: "неделя"
  def script_clock_label(count, "week", "ru") when count in 2..4, do: "недели"
  def script_clock_label(_count, "week", "ru"), do: "недель"
  def script_clock_label(1, _label, "ru"), do: "раунд"
  def script_clock_label(count, _label, "ru") when count in 2..4, do: "раунда"
  def script_clock_label(_count, _label, "ru"), do: "раундов"
  def script_clock_label(1, label, _locale), do: context_identifier(label, "en")

  def script_clock_label(_count, label, _locale),
    do: context_identifier(label, "en") <> "s"

  def script_condition_summary(nil, locale), do: t(locale, :script_condition_always)
  def script_condition_summary(true, locale), do: t(locale, :script_condition_always)

  def script_condition_summary(%{"fact" => fact, "op" => op, "value" => value}, locale) do
    tx(locale, :script_condition_fact,
      fact: condition_fact_label(fact, locale),
      operator: condition_operator(op, locale),
      value: script_value(value, locale)
    )
  end

  def script_condition_summary(%{"all" => conditions}, locale) when is_list(conditions),
    do: tx(locale, :script_condition_all, count: length(conditions))

  def script_condition_summary(%{"any" => conditions}, locale) when is_list(conditions),
    do: tx(locale, :script_condition_any, count: length(conditions))

  def script_condition_summary(_condition, locale), do: t(locale, :script_condition_typed)

  def script_resource_bounds(%{"constraints" => constraints}, locale) when is_map(constraints) do
    tx(locale, :script_resource_range,
      minimum: script_value(constraints["min"], locale),
      maximum: script_value(constraints["max"], locale)
    )
  end

  def script_resource_bounds(_resource, locale), do: t(locale, :script_resource_bounded)

  def script_phase_key("after_actions"), do: :script_phase_after
  def script_phase_key(_phase), do: :script_phase_before

  def script_policy_key("fixed"), do: :script_policy_fixed
  def script_policy_key("rule_set"), do: :script_policy_rules
  def script_policy_key("hybrid"), do: :script_policy_hybrid
  def script_policy_key(_kind), do: :script_policy_weighted

  def script_policy_summary(%{"kind" => "fixed", "action" => action}, locale),
    do: tx(locale, :script_policy_fixed_summary, action: context_identifier(action, locale))

  def script_policy_summary(%{"kind" => "weighted", "candidates" => candidates}, locale)
      when is_map(candidates) do
    count = map_size(candidates)

    if locale == "ru" do
      "Ранжирует #{count} #{russian_plural(count, "заданный вариант", "заданных варианта", "заданных вариантов")} по типизированным оценкам."
    else
      tx(locale, :script_policy_weighted_summary, count: count)
    end
  end

  def script_policy_summary(%{"kind" => "rule_set", "rules" => rules}, locale)
      when is_list(rules),
      do: tx(locale, :script_policy_rules_summary, count: length(rules))

  def script_policy_summary(%{"kind" => "hybrid"}, locale),
    do: t(locale, :script_policy_hybrid_summary)

  def script_policy_summary(_policy, locale), do: t(locale, :script_policy_typed_summary)

  def script_metric_key("agent_fraction"), do: :script_metric_fraction
  def script_metric_key("agent_mean"), do: :script_metric_mean
  def script_metric_key("action_count"), do: :script_metric_action
  def script_metric_key("resource_sum"), do: :script_metric_resource
  def script_metric_key("relationship_count"), do: :script_metric_relationship
  def script_metric_key(_kind), do: :script_metric_world

  defp condition_fact_label("world." <> fact, locale), do: context_identifier(fact, locale)
  defp condition_fact_label("agent." <> fact, locale), do: context_identifier(fact, locale)
  defp condition_fact_label(fact, locale), do: context_identifier(fact, locale)

  defp condition_operator("eq", "ru"), do: "равно"
  defp condition_operator("neq", "ru"), do: "не равно"
  defp condition_operator("gt", "ru"), do: "больше"
  defp condition_operator("gte", "ru"), do: "не меньше"
  defp condition_operator("lt", "ru"), do: "меньше"
  defp condition_operator("lte", "ru"), do: "не больше"
  defp condition_operator("in", "ru"), do: "входит в"
  defp condition_operator("neq", _locale), do: "is not"
  defp condition_operator("gt", _locale), do: "is above"
  defp condition_operator("gte", _locale), do: "is at least"
  defp condition_operator("lt", _locale), do: "is below"
  defp condition_operator("lte", _locale), do: "is at most"
  defp condition_operator("in", _locale), do: "is one of"
  defp condition_operator(_operator, _locale), do: "is"

  defp localize_compound_identifier("round"), do: "Раунд"
  defp localize_compound_identifier("week"), do: "Неделя"
  defp localize_compound_identifier("points"), do: "Баллы"
  defp localize_compound_identifier("hours"), do: "Часы"

  defp localize_compound_identifier(identifier) when is_binary(identifier) do
    cond do
      String.ends_with?(identifier, "_response_policy") ->
        type = String.replace_suffix(identifier, "_response_policy", "")
        "Политика: #{context_identifier(type, "ru") |> String.downcase()}"

      String.ends_with?(identifier, "_count") ->
        action = String.replace_suffix(identifier, "_count", "")
        "#{context_identifier(action, "ru")} · количество"

      String.ends_with?(identifier, "_total") ->
        resource = String.replace_suffix(identifier, "_total", "")
        "#{context_identifier(resource, "ru")} · всего"

      true ->
        humanize_identifier(identifier)
    end
  end

  defp localize_compound_identifier(identifier), do: humanize_identifier(identifier)

  defp humanize_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_identifier(_identifier), do: "—"

  defp grouped_number(value, separator) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(separator, &Enum.join/1)
    |> String.reverse()
  end

  defp english_plural(1, singular), do: singular
  defp english_plural(_count, singular), do: singular <> "s"

  defp russian_plural(count, singular, paucal, plural) do
    mod_100 = rem(count, 100)
    mod_10 = rem(count, 10)

    cond do
      mod_100 in 11..14 -> plural
      mod_10 == 1 -> singular
      mod_10 in 2..4 -> paucal
      true -> plural
    end
  end
end
