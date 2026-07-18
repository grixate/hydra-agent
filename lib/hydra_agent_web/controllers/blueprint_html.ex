defmodule HydraAgentWeb.BlueprintHTML do
  use HydraAgentWeb, :html

  alias HydraAgent.Simulations.BlueprintManifest
  alias HydraAgentWeb.BlueprintCopy

  def t(locale, key), do: BlueprintCopy.t(locale, key)

  def localized(value, locale) when is_map(value),
    do: value[locale] || value["en"] || value |> Map.values() |> List.first() || ""

  def localized(_value, _locale), do: ""

  def module_title(locale, module), do: t(locale, String.to_existing_atom(module))
  def module_hint(locale, module), do: t(locale, String.to_existing_atom(module <> "_hint"))

  def module_number("research"), do: "01"
  def module_number("agents"), do: "02"
  def module_number("simulation"), do: "03"
  def module_number("report"), do: "04"

  def schema_for(version, module) do
    path = get_in(version.manifest, ["modules", module, "output_schema"])
    version.schemas[path] || %{}
  end

  def schema_json(version, module),
    do: version |> schema_for(module) |> Jason.encode!(pretty: true)

  def sample_for(version, "research"), do: version.examples["examples/sample-context.json"]
  def sample_for(version, "agents"), do: version.examples["examples/sample-population.json"]
  def sample_for(version, "simulation"), do: version.examples["examples/sample-script.yaml"]
  def sample_for(version, "report"), do: version.examples["examples/sample-report.json"]

  def short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)
  def short_hash(_hash), do: "—"

  def manifest_yaml(version), do: BlueprintManifest.encode(version.manifest)

  def index_path(workspace_id, locale) do
    "/blueprints?" <> URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def show_path(blueprint_id, workspace_id, locale) do
    "/blueprints/#{blueprint_id}?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  def edit_path(blueprint_id, workspace_id, locale) do
    "/blueprints/#{blueprint_id}/edit?" <>
      URI.encode_query(%{"workspace_id" => workspace_id, "locale" => locale})
  end

  embed_templates "blueprint_html/*"
end
