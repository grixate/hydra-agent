defmodule HydraAgentWeb.SimulationObservatoryComponents do
  @moduledoc "Accessible State, Flow, and Explain components for Simulation results."

  use HydraAgentWeb, :html

  alias HydraAgentWeb.SimulationCopy

  attr :payload, :map, required: true
  attr :simulation, :any, required: true
  attr :workspace, :any, required: true
  attr :run, :any, required: true
  attr :comparison_runs, :list, default: []
  attr :selected_comparison, :any, default: nil
  attr :locale, :string, required: true

  def observatory(assigns) do
    assigns =
      assigns
      |> assign(:payload_url, payload_path(assigns))
      |> assign(:agent_url_base, agent_path(assigns))
      |> assign(:comparison, assigns.payload["comparison"] || %{"status" => "none"})
      |> assign(:state, assigns.payload["state"] || %{})
      |> assign(:flow, assigns.payload["flow"] || %{})
      |> assign(:explain, assigns.payload["explain"] || %{})

    ~H"""
    <section
      id="simulation-observatory"
      class="simulation-observatory"
      data-observatory
      data-locale={@locale}
      data-payload-url={@payload_url}
      data-agent-url-base={@agent_url_base}
      data-copy-loading={t(@locale, :observatory_loading)}
      data-copy-error={t(@locale, :observatory_error)}
      data-copy-agent-loading={t(@locale, :observatory_agent_loading)}
      data-copy-agent-error={t(@locale, :observatory_agent_error)}
      data-copy-synthetic={t(@locale, :observatory_agent_synthetic)}
      data-copy-zoom-density={t(@locale, :observatory_zoom_density)}
      data-copy-zoom-cohorts={t(@locale, :observatory_zoom_cohorts)}
      data-copy-zoom-samples={t(@locale, :observatory_zoom_samples)}
      data-copy-persona={t(@locale, :observatory_persona)}
      data-copy-current-state={t(@locale, :observatory_current_state)}
      data-copy-resources={t(@locale, :observatory_resources)}
      data-copy-attributes={t(@locale, :observatory_attributes)}
      data-copy-goals={t(@locale, :observatory_goals)}
      data-copy-constraints={t(@locale, :observatory_constraints)}
      data-copy-history={t(@locale, :observatory_history)}
      data-copy-round={t(@locale, :observatory_round)}
      data-copy-action={t(@locale, :observatory_action)}
      data-copy-state={t(@locale, :observatory_state_label)}
      data-copy-decisions={t(@locale, :observatory_decisions)}
      data-copy-affected={t(@locale, :observatory_affected)}
      data-copy-perceived-context={t(@locale, :observatory_perceived_context)}
      data-copy-relationships={t(@locale, :observatory_relationships)}
      data-copy-grounding={t(@locale, :observatory_grounding)}
      aria-labelledby="observatory-title"
    >
      <header class="simulation-observatory-header">
        <div>
          <p class="blueprint-eyebrow">{t(@locale, :observatory_label)}</p>
          <h2 id="observatory-title">{main_result(@payload["main_result"], @locale)}</h2>
          <p>{t(@locale, :observatory_lede)}</p>
        </div>
        <.comparison_control
          simulation={@simulation}
          workspace={@workspace}
          run={@run}
          comparison_runs={@comparison_runs}
          selected_comparison={@selected_comparison}
          locale={@locale}
        />
      </header>

      <aside
        :if={@comparison["status"] == "ready"}
        class={[
          "simulation-comparison-note",
          @comparison["directly_comparable"] && "is-compatible"
        ]}
        role="status"
      >
        <span aria-hidden="true">{if @comparison["directly_comparable"], do: "✓", else: "!"}</span>
        <div>
          <strong>
            {t(
              @locale,
              if(@comparison["directly_comparable"],
                do: :observatory_comparable,
                else: :observatory_not_comparable
              )
            )}
          </strong>
          <p>
            {t(
              @locale,
              if(@comparison["directly_comparable"],
                do: :observatory_comparable_lede,
                else: :observatory_not_comparable_lede
              )
            )}
          </p>
          <ul :if={@comparison["differences"] != []}>
            <li :for={difference <- @comparison["differences"]}>
              {identifier(difference["field"], @locale)}
            </li>
          </ul>
        </div>
        <a href={results_path(@simulation.id, @workspace.id, @locale)}>
          {t(@locale, :observatory_clear_comparison)}
        </a>
      </aside>

      <nav class="simulation-observatory-lenses" aria-label={t(@locale, :observatory_lenses)}>
        <a href="#observatory-state" data-observatory-lens="state" aria-current="page">
          <span>01</span>
          <strong>{t(@locale, :observatory_state)}</strong>
          <small>{t(@locale, :observatory_state_question)}</small>
        </a>
        <a href="#observatory-flow" data-observatory-lens="flow">
          <span>02</span>
          <strong>{t(@locale, :observatory_flow)}</strong>
          <small>{t(@locale, :observatory_flow_question)}</small>
        </a>
        <a href="#observatory-explain" data-observatory-lens="explain">
          <span>03</span>
          <strong>{t(@locale, :observatory_explain)}</strong>
          <small>{t(@locale, :observatory_explain_question)}</small>
        </a>
      </nav>

      <section
        id="observatory-state"
        class="simulation-observatory-panel"
        data-observatory-panel="state"
        aria-labelledby="observatory-state-title"
      >
        <header class="simulation-observatory-panel-header">
          <div>
            <p class="blueprint-eyebrow">{t(@locale, :observatory_state)}</p>
            <h3 id="observatory-state-title">{t(@locale, :observatory_state_title)}</h3>
            <p>{t(@locale, :observatory_state_lede)}</p>
          </div>
          <span>{t(@locale, :observatory_aggregate_only)}</span>
        </header>

        <div class="simulation-state-layout">
          <section
            class="simulation-observatory-visual"
            aria-label={t(@locale, :observatory_state_visual)}
          >
            <div class="simulation-observatory-toolbar">
              <span>{t(@locale, :observatory_semantic_zoom)}</span>
              <div>
                <button
                  type="button"
                  data-observatory-zoom-out
                  aria-label={t(@locale, :observatory_zoom_out)}
                >
                  −
                </button>
                <output data-observatory-zoom-label>{t(@locale, :observatory_zoom_cohorts)}</output>
                <button
                  type="button"
                  data-observatory-zoom-in
                  aria-label={t(@locale, :observatory_zoom_in)}
                >
                  +
                </button>
              </div>
            </div>
            <div class="simulation-observatory-canvas-frame">
              <canvas
                data-observatory-state-canvas
                width="900"
                height="480"
                tabindex="0"
                role="img"
                aria-label={t(@locale, :observatory_state_canvas_label)}
                aria-describedby="observatory-state-hint"
              >
                {t(@locale, :observatory_canvas_fallback)}
              </canvas>
              <p data-observatory-visual-status aria-live="polite">
                {t(@locale, :observatory_loading)}
              </p>
            </div>
            <p id="observatory-state-hint" class="simulation-observatory-hint">
              {t(@locale, :observatory_state_hint)}
            </p>
            <ul class="simulation-observatory-legend" aria-label={t(@locale, :observatory_legend)}>
              <li><i class="is-current"></i>{t(@locale, :observatory_current_run)}</li>
              <li :if={@comparison["status"] == "ready"}>
                <i class="is-baseline"></i>{t(@locale, :observatory_baseline_run)}
              </li>
            </ul>
          </section>

          <aside class="simulation-state-summary">
            <dl>
              <div>
                <dt>{t(@locale, :population)}</dt>
                <dd>{format_count(@payload["run"]["population_size"], @locale)}</dd>
              </div>
              <div>
                <dt>{t(@locale, :observatory_model_decisions)}</dt>
                <dd>{@payload["run"]["model_decisions"]}</dd>
              </div>
              <div>
                <dt>{t(@locale, :observatory_personas)}</dt>
                <dd>{@payload["run"]["representative_personas"]}</dd>
              </div>
              <div>
                <dt>{t(@locale, :observatory_relationships)}</dt>
                <dd>{format_count(@payload["run"]["relationship_count"], @locale)}</dd>
              </div>
            </dl>

            <div class="simulation-observatory-samples">
              <header>
                <strong>{t(@locale, :observatory_inspect_agent)}</strong>
                <small>{t(@locale, :observatory_agent_on_demand)}</small>
              </header>
              <div>
                <button
                  :for={sample <- Enum.take(@state["samples"] || [], 8)}
                  type="button"
                  data-observatory-agent={sample["id"]}
                >
                  <span>{identifier(sample["type"], @locale)}</span>
                  <small>{short_agent(sample["id"], @locale)}</small>
                </button>
              </div>
            </div>
          </aside>
        </div>

        <section
          id="observatory-agent-inspector"
          class="simulation-agent-inspector"
          data-observatory-inspector
          aria-live="polite"
          aria-busy="false"
        >
          <header>
            <div>
              <p class="blueprint-eyebrow">{t(@locale, :observatory_agent_inspector)}</p>
              <h3 data-observatory-inspector-title tabindex="-1">
                {t(@locale, :observatory_agent_empty)}
              </h3>
            </div>
            <span>{t(@locale, :observatory_loaded_on_demand)}</span>
          </header>
          <div data-observatory-inspector-content>
            <p>{t(@locale, :observatory_agent_empty_lede)}</p>
          </div>
        </section>

        <details class="simulation-observatory-alternative" open>
          <summary>
            <strong>{t(@locale, :observatory_state_table)}</strong>
            <small>{t(@locale, :observatory_accessible_alternative)}</small>
          </summary>
          <div class="simulation-observatory-table-scroll" tabindex="0">
            <table>
              <caption>{t(@locale, :observatory_cohort_table_caption)}</caption>
              <thead>
                <tr>
                  <th scope="col">{t(@locale, :observatory_cohort)}</th>
                  <th scope="col">{t(@locale, :observatory_count)}</th>
                  <th scope="col">{t(@locale, :observatory_share)}</th>
                  <th :if={@comparison["status"] == "ready"} scope="col">
                    {t(@locale, :observatory_change)}
                  </th>
                  <th scope="col">{t(@locale, :observatory_common_action)}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={cohort <- Enum.filter(@state["cohorts"] || [], &(&1["kind"] == "type"))}>
                  <th scope="row">{identifier(cohort["id"], @locale)}</th>
                  <td>{format_count(cohort["count"], @locale)}</td>
                  <td>{format_percent(cohort["share"])}</td>
                  <td :if={@comparison["status"] == "ready"}>
                    {signed_percent(cohort["share_delta"])}
                  </td>
                  <td>{top_action(cohort["last_actions"], @locale)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="simulation-observatory-table-pair">
            <div class="simulation-observatory-table-scroll" tabindex="0">
              <table>
                <caption>{t(@locale, :observatory_resource_table_caption)}</caption>
                <thead>
                  <tr>
                    <th scope="col">{t(@locale, :observatory_resource)}</th>
                    <th scope="col">{t(@locale, :observatory_minimum)}</th>
                    <th scope="col">{t(@locale, :observatory_mean)}</th>
                    <th scope="col">{t(@locale, :observatory_maximum)}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={resource <- @state["resources"] || []}>
                    <th scope="row">{identifier(resource["resource"], @locale)}</th>
                    <td>{format_value(resource["minimum"])}</td>
                    <td>{format_value(resource["mean"])}</td>
                    <td>{format_value(resource["maximum"])}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="simulation-observatory-table-scroll" tabindex="0">
              <table>
                <caption>{t(@locale, :observatory_state_distribution)}</caption>
                <thead>
                  <tr>
                    <th scope="col">{t(@locale, :observatory_state_field)}</th>
                    <th scope="col">{t(@locale, :observatory_value)}</th>
                    <th scope="col">{t(@locale, :observatory_count)}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={state <- @state["state_distribution"] || []}>
                    <th scope="row">{identifier(state["key"], @locale)}</th>
                    <td>{identifier(state["value"], @locale)}</td>
                    <td>{format_count(state["count"], @locale)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </details>
      </section>

      <section
        id="observatory-flow"
        class="simulation-observatory-panel"
        data-observatory-panel="flow"
        aria-labelledby="observatory-flow-title"
      >
        <header class="simulation-observatory-panel-header">
          <div>
            <p class="blueprint-eyebrow">{t(@locale, :observatory_flow)}</p>
            <h3 id="observatory-flow-title">{t(@locale, :observatory_flow_title)}</h3>
            <p>{t(@locale, :observatory_flow_lede)}</p>
          </div>
          <span>{t(@locale, :observatory_ordered_record)}</span>
        </header>

        <section class="simulation-observatory-visual simulation-flow-visual">
          <div class="simulation-flow-toolbar">
            <label for="observatory-round">
              <span>{t(@locale, :observatory_round)}</span>
              <output data-observatory-round-output>{@payload["run"]["rounds"]}</output>
            </label>
            <input
              id="observatory-round"
              type="range"
              min="1"
              max={max(@payload["run"]["rounds"] || 1, 1)}
              value={max(@payload["run"]["rounds"] || 1, 1)}
              data-observatory-round
            />
          </div>
          <div class="simulation-observatory-canvas-frame">
            <canvas
              data-observatory-flow-canvas
              width="1100"
              height="440"
              tabindex="0"
              role="img"
              aria-label={t(@locale, :observatory_flow_canvas_label)}
              aria-describedby="observatory-flow-hint"
            >
              {t(@locale, :observatory_canvas_fallback)}
            </canvas>
          </div>
          <p id="observatory-flow-hint" class="simulation-observatory-hint">
            {t(@locale, :observatory_flow_hint)}
          </p>
        </section>

        <div class="simulation-flow-grid">
          <details class="simulation-observatory-alternative" open>
            <summary>
              <strong>{t(@locale, :observatory_timeline_table)}</strong>
              <small>{t(@locale, :observatory_accessible_alternative)}</small>
            </summary>
            <div class="simulation-observatory-table-scroll" tabindex="0">
              <table>
                <caption>{t(@locale, :observatory_timeline_caption)}</caption>
                <thead>
                  <tr>
                    <th scope="col">{t(@locale, :observatory_round)}</th>
                    <th :for={metric <- Enum.take(@flow["metric_ids"] || [], 4)} scope="col">
                      {identifier(metric, @locale)}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={point <- @flow["timeline"] || []}>
                    <th scope="row">{point["round"]}</th>
                    <td :for={metric <- Enum.take(@flow["metric_ids"] || [], 4)}>
                      {format_value(get_in(point, ["metrics", metric]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </details>

          <section class="simulation-pivotal-timeline">
            <header>
              <strong>{t(@locale, :observatory_pivotal_events)}</strong>
              <small>{length(@flow["pivotal_events"] || [])}</small>
            </header>
            <ol>
              <li :for={event <- @flow["pivotal_events"] || []}>
                <span>{event["round"]}</span>
                <div>
                  <strong>{event_summary(event, @locale)}</strong>
                  <small>{identifier(event["phase"], @locale)} · <code>{event["ref"]}</code></small>
                </div>
              </li>
            </ol>
          </section>
        </div>

        <details class="simulation-observatory-alternative" open>
          <summary>
            <strong>{t(@locale, :observatory_resource_flows)}</strong>
            <small>{t(@locale, :observatory_resource_flows_lede)}</small>
          </summary>
          <div class="simulation-observatory-table-scroll" tabindex="0">
            <table>
              <caption>{t(@locale, :observatory_resource_flow_caption)}</caption>
              <thead>
                <tr>
                  <th scope="col">{t(@locale, :observatory_resource)}</th>
                  <th scope="col">{t(@locale, :observatory_from)}</th>
                  <th scope="col">{t(@locale, :observatory_to)}</th>
                  <th scope="col">{t(@locale, :observatory_operation)}</th>
                  <th scope="col">{t(@locale, :observatory_amount)}</th>
                  <th :if={@comparison["status"] == "ready"} scope="col">
                    {t(@locale, :observatory_change)}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={flow <- @flow["resource_flows"] || []}>
                  <th scope="row">{identifier(flow["resource"], @locale)}</th>
                  <td>{identifier(flow["source"], @locale)}</td>
                  <td>{identifier(flow["destination"], @locale)}</td>
                  <td>{identifier(flow["operation"], @locale)}</td>
                  <td>{flow["amount"]}</td>
                  <td :if={@comparison["status"] == "ready"}>
                    {signed_value(flow["amount_delta"])}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </details>
      </section>

      <section
        id="observatory-explain"
        class="simulation-observatory-panel"
        data-observatory-panel="explain"
        aria-labelledby="observatory-explain-title"
      >
        <header class="simulation-observatory-panel-header">
          <div>
            <p class="blueprint-eyebrow">{t(@locale, :observatory_explain)}</p>
            <h3 id="observatory-explain-title">{t(@locale, :observatory_explain_title)}</h3>
            <p>{t(@locale, :observatory_explain_lede)}</p>
          </div>
          <span>{t(@locale, :observatory_not_causal)}</span>
        </header>

        <aside class="simulation-modeled-driver-note">
          <span aria-hidden="true">◇</span>
          <p>
            <strong>{t(@locale, :observatory_modeled_drivers)}</strong>
            {t(@locale, :observatory_modeled_drivers_lede)}
          </p>
        </aside>

        <ol class="simulation-modeled-drivers">
          <li :for={{driver, index} <- Enum.with_index(@explain["modeled_drivers"] || [], 1)}>
            <span>{index |> Integer.to_string() |> String.pad_leading(2, "0")}</span>
            <div>
              <header>
                <strong>{driver_label(driver, @locale)}</strong>
                <small>{identifier(driver["kind"], @locale)}</small>
              </header>
              <p :if={driver["detail"] not in [nil, ""]}>{driver["detail"]}</p>
              <progress
                class="simulation-driver-meter"
                max="1"
                value={driver["strength"] || 0}
                aria-label={"#{driver_label(driver, @locale)} · #{format_percent(driver["strength"])}"}
              >
                {format_percent(driver["strength"])}
              </progress>
              <footer>
                <code>{driver["ref"]}</code>
                <span>{format_percent(driver["strength"])}</span>
              </footer>
            </div>
          </li>
        </ol>

        <div class="simulation-explain-grid">
          <details :if={@explain["model_decisions"] != []} class="simulation-explain-details" open>
            <summary>
              <strong>{t(@locale, :observatory_model_decision_patterns)}</strong>
              <small>{length(@explain["model_decisions"])}</small>
            </summary>
            <ol>
              <li :for={decision <- @explain["model_decisions"]}>
                <span>{decision["round"]}</span>
                <div>
                  <strong>{identifier(decision["action_id"], @locale)}</strong>
                  <p>{decision["short_rationale"]}</p>
                  <small>
                    {format_count(decision["affected_agents"], @locale)} {t(
                      @locale,
                      :observatory_agents_affected
                    )} · {identifier(decision["source"], @locale)}
                  </small>
                </div>
              </li>
            </ol>
          </details>

          <details class="simulation-explain-details" open>
            <summary>
              <strong>{t(@locale, :observatory_grounding)}</strong>
              <small>{length(@explain["grounding"] || [])}</small>
            </summary>
            <ul>
              <li :for={item <- Enum.take(@explain["grounding"] || [], 12)}>
                <span>{identifier(item["kind"], @locale)}</span>
                <p>{item["statement"] || item["title"] || item["code"]}</p>
                <code>{item["ref"]}</code>
              </li>
            </ul>
          </details>
        </div>

        <details class="simulation-observatory-uncertainty" open>
          <summary>{t(@locale, :observatory_uncertainty)}</summary>
          <dl>
            <div>
              <dt>{t(@locale, :observatory_context_confidence)}</dt>
              <dd>{format_percent(@explain["uncertainty"]["context_confidence"])}</dd>
            </div>
            <div>
              <dt>{t(@locale, :observatory_policy_uncertainty)}</dt>
              <dd>{format_percent(@explain["uncertainty"]["policy_uncertainty_mean"])}</dd>
            </div>
            <div>
              <dt>{t(@locale, :analysis_robustness)}</dt>
              <dd>{identifier(@explain["uncertainty"]["robustness_status"], @locale)}</dd>
            </div>
            <div>
              <dt>{t(@locale, :observatory_fallbacks)}</dt>
              <dd>{@explain["uncertainty"]["fallback_count"]}</dd>
            </div>
          </dl>
          <p>{t(@locale, :observatory_uncertainty_lede)}</p>
        </details>
      </section>

      <footer class="simulation-observatory-footer">
        <p>
          {t(@locale, :observatory_protocol)} <code>{@payload["protocol_version"]}</code>
        </p>
        <span>
          {format_bytes(@payload["compressed_bytes"], @locale)} · {length(@state["samples"] || [])} {t(
            @locale,
            :observatory_bounded_samples
          )}
        </span>
      </footer>
    </section>
    """
  end

  attr :simulation, :any, required: true
  attr :workspace, :any, required: true
  attr :run, :any, required: true
  attr :comparison_runs, :list, default: []
  attr :selected_comparison, :any, default: nil
  attr :locale, :string, required: true

  defp comparison_control(assigns) do
    ~H"""
    <div class="simulation-comparison-control">
      <form
        :if={@comparison_runs != []}
        action={"/simulations/#{@simulation.id}/compare"}
        method="get"
      >
        <input type="hidden" name="workspace_id" value={@workspace.id} />
        <input type="hidden" name="locale" value={@locale} />
        <input type="hidden" name="run_id" value={@run.id} />
        <label for="observatory-compare-run">{t(@locale, :observatory_compare_with)}</label>
        <div>
          <select id="observatory-compare-run" name="compare_run_id" required>
            <option value="">{t(@locale, :observatory_choose_run)}</option>
            <option
              :for={record <- @comparison_runs}
              value={record.id}
              selected={@selected_comparison && @selected_comparison.id == record.id}
            >
              {comparison_label(record, @locale)}
            </option>
          </select>
          <button type="submit">{t(@locale, :observatory_compare_action)}</button>
        </div>
      </form>
      <div :if={@comparison_runs == []}>
        <strong>{t(@locale, :observatory_comparison_unavailable)}</strong>
        <small>{t(@locale, :observatory_comparison_unavailable_lede)}</small>
      </div>
    </div>
    """
  end

  defp t(locale, key), do: SimulationCopy.t(locale, key)

  defp payload_path(assigns) do
    query =
      %{
        "workspace_id" => assigns.workspace.id,
        "locale" => assigns.locale,
        "run_id" => assigns.run.id,
        "compare_run_id" => assigns.selected_comparison && assigns.selected_comparison.id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> URI.encode_query()

    "/simulations/#{assigns.simulation.id}/results/observatory.json?#{query}"
  end

  defp agent_path(assigns) do
    query =
      URI.encode_query(%{
        "workspace_id" => assigns.workspace.id,
        "locale" => assigns.locale,
        "run_id" => assigns.run.id
      })

    "/simulations/#{assigns.simulation.id}/results/observatory/agents/__agent__/detail.json?#{query}"
  end

  defp results_path(simulation_id, workspace_id, locale) do
    "/simulations/#{simulation_id}/results?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  defp comparison_label(record, locale) do
    lineage = identifier(record.replay_kind, locale)
    mode = identifier(record.mode, locale)
    "##{record.id} · #{mode} · #{lineage} · seed #{record.seed}"
  end

  defp main_result(%{"id" => id, "final" => final, "direction" => direction} = result, "ru") do
    "#{identifier(id, "ru")}: #{metric_value(final, result["unit"])} · #{direction_label(direction, "ru")}"
  end

  defp main_result(%{"id" => id, "final" => final, "direction" => direction} = result, _locale) do
    "#{identifier(id, "en")}: #{metric_value(final, result["unit"])} · #{direction_label(direction, "en")}"
  end

  defp main_result(_result, locale), do: t(locale, :observatory_result_recorded)

  defp metric_value(value, "fraction") when is_number(value), do: format_percent(value)
  defp metric_value(value, _unit), do: format_value(value)

  defp direction_label("increased", "ru"), do: "рост"
  defp direction_label("decreased", "ru"), do: "снижение"
  defp direction_label("stable", "ru"), do: "без изменений"
  defp direction_label("increased", _locale), do: "increased"
  defp direction_label("decreased", _locale), do: "decreased"
  defp direction_label("stable", _locale), do: "stable"
  defp direction_label(_direction, "ru"), do: "зафиксировано"
  defp direction_label(_direction, _locale), do: "recorded"

  defp identifier(nil, _locale), do: "—"

  defp identifier(value, "ru") do
    Map.get(
      %{
        "participant" => "Участники",
        "decision_maker" => "Лица, принимающие решения",
        "influencer" => "Лидеры мнений",
        "time" => "Время",
        "information" => "Информация",
        "influence" => "Влияние",
        "trust" => "Доверие",
        "last_action" => "Последнее действие",
        "phase" => "Состояние",
        "uncommitted" => "Без решения",
        "adopt" => "Принять",
        "delay" => "Отложить",
        "resist" => "Отказаться",
        "influence_others" => "Повлиять на других",
        "transfer" => "Передача",
        "mint" => "Создание",
        "burn" => "Списание",
        "event" => "Событие",
        "decision" => "Решение модели",
        "action" => "Действие",
        "model" => "Модель",
        "exact_replay" => "Точный повтор",
        "fresh_rerun" => "Новый запуск",
        "original" => "Исходный запуск",
        "balanced" => "Сбалансированный",
        "quick" => "Быстрый",
        "available" => "Доступна",
        "insufficient_runs" => "Нужны дополнительные запуски",
        "population_model" => "Модель популяции",
        "simulation_script" => "Правила симуляции",
        "execution_mode" => "Режим выполнения",
        "model_route" => "Маршрут модели",
        "budget" => "Бюджет",
        "primary_action_rate" => "Доля основного действия",
        "adopt_count" => "Выбрали принятие",
        "delay_count" => "Выбрали отсрочку",
        "influence_others_count" => "Выбрали влияние на других",
        "resist_count" => "Выбрали отказ",
        "influence_total" => "Суммарное влияние",
        "information_total" => "Суммарная информация",
        "time_total" => "Суммарное время",
        "rule" => "Правило",
        "fallback" => "Резервное правило",
        "recorded_decision" => "Записанное решение",
        "signature_reuse" => "Повтор по сигнатуре",
        "incoming" => "Входящая",
        "outgoing" => "Исходящая",
        "undirected" => "Ненаправленная",
        "claim" => "Утверждение",
        "assumption" => "Допущение",
        "simulation_begins" => "Начало симуляции",
        "simulation begins" => "Начало симуляции"
      },
      to_string(value),
      humanize(value)
    )
  end

  defp identifier(value, _locale), do: humanize(value)

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("agent_type:", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp short_agent(agent_id, locale) do
    suffix = agent_id |> to_string() |> String.replace_prefix("agent-", "") |> String.slice(0, 8)
    "#{if locale == "ru", do: "Агент", else: "Agent"} · #{suffix}"
  end

  defp event_summary(%{"type" => "simulation.world_event", "payload" => payload}, "ru"),
    do: "Применено плановое событие · #{identifier(payload["event_id"], "ru")}"

  defp event_summary(%{"type" => "simulation.transition", "payload" => payload}, "ru"),
    do: "Применён переход · #{identifier(payload["transition_id"], "ru")}"

  defp event_summary(%{"summary" => summary}, "ru") do
    cond do
      String.starts_with?(summary, "Scheduled event applied · ") ->
        event_id = String.replace_prefix(summary, "Scheduled event applied · ", "")
        "Применено плановое событие · #{identifier(event_id, "ru")}"

      String.starts_with?(summary, "Transition applied · ") ->
        transition_id = String.replace_prefix(summary, "Transition applied · ", "")
        "Применён переход · #{identifier(transition_id, "ru")}"

      true ->
        case Regex.run(~r/^(\d+) agents selected ([\p{L}\p{N}_:-]+)$/u, summary) do
          [_, count, action] ->
            "#{count} агентов выбрали действие «#{identifier(action, "ru")}»"

          _other ->
            summary
        end
    end
  end

  defp event_summary(event, _locale), do: event["summary"] || identifier(event["type"], "en")

  defp driver_label(%{"kind" => "event"} = driver, locale),
    do: event_summary(%{"summary" => driver["label"]}, locale)

  defp driver_label(%{"kind" => "action", "label" => "action:" <> action}, locale),
    do: identifier(action, locale)

  defp driver_label(driver, locale), do: identifier(driver["label"], locale)

  defp top_action(actions, locale) when is_map(actions) and map_size(actions) > 0 do
    actions
    |> Enum.max_by(fn {action, count} -> {count, action} end)
    |> elem(0)
    |> identifier(locale)
  end

  defp top_action(_actions, _locale), do: "—"

  defp format_count(value, "ru") when is_integer(value), do: grouped(value, " ")
  defp format_count(value, _locale) when is_integer(value), do: grouped(value, ",")
  defp format_count(value, _locale), do: format_value(value)

  defp grouped(value, separator) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(separator, &Enum.join/1)
    |> String.reverse()
  end

  defp format_percent(nil), do: "—"
  defp format_percent(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_percent(_value), do: "—"

  defp signed_percent(nil), do: "—"
  defp signed_percent(value) when is_number(value) and value > 0, do: "+#{format_percent(value)}"
  defp signed_percent(value) when is_number(value), do: format_percent(value)
  defp signed_percent(_value), do: "—"

  defp signed_value(nil), do: "—"
  defp signed_value(value) when is_number(value) and value > 0, do: "+#{format_value(value)}"
  defp signed_value(value), do: format_value(value)

  defp format_value(nil), do: "—"
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_float(value),
    do: value |> Float.round(3) |> :erlang.float_to_binary([:compact, decimals: 3])

  defp format_value(value), do: to_string(value)

  defp format_bytes(bytes, "ru") when is_integer(bytes), do: "#{Float.round(bytes / 1024, 1)} КБ"

  defp format_bytes(bytes, _locale) when is_integer(bytes),
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(_bytes, _locale), do: "—"
end
