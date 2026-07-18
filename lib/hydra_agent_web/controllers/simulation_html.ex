defmodule HydraAgentWeb.SimulationHTML do
  use HydraAgentWeb, :html

  alias HydraAgentWeb.SimulationCopy

  embed_templates "simulation_html/*"

  def t(locale, key), do: SimulationCopy.t(locale, key)
  def tx(locale, key, values), do: SimulationCopy.interpolate(locale, key, values)

  def localized(value, locale) when is_map(value) do
    value[locale] || value["en"] || "Blueprint"
  end

  def status_key("archived"), do: :archived_status
  def status_key(status), do: String.to_existing_atom(status)

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
        "adopt" => "Принять",
        "delay" => "Отложить",
        "resist" => "Отказаться",
        "influence_others" => "Повлиять на других",
        "comply_reluctantly" => "Подчиниться без согласия"
      },
      identifier,
      humanize_identifier(identifier)
    )
  end

  def context_identifier(identifier, _locale), do: humanize_identifier(identifier)

  def source_host(%{"uri" => uri}) when is_binary(uri), do: URI.parse(uri).host
  def source_host(_source), do: nil

  def claim_source(%{"source_id" => source_id}, sources) when is_binary(source_id) do
    Enum.find(sources, &(&1["id"] == source_id))
  end

  def claim_source(_claim, _sources), do: nil

  defp humanize_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_identifier(_identifier), do: "—"

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
