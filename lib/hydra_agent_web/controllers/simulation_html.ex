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
end
