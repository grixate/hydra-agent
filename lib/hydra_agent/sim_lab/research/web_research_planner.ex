defmodule HydraAgent.SimLab.Research.WebResearchPlanner do
  @moduledoc """
  Produces explicit, privacy-safe search lanes for low-data studies.

  The planner outputs query intent and the abstracted text separately; callers
  must use `safe_query` for any external provider request.
  """

  alias HydraAgent.SimLab.Research.QueryAbstractor

  @lanes [
    {"market_context", "Understand category and geography"},
    {"competitor_analogue", "Find similar product launches and outcomes"},
    {"behavioral_research", "Find observed motivations, frictions, and habits"},
    {"regulatory", "Find relevant privacy, data, and local constraints"},
    {"recent_news", "Find changes that could affect the forecast"},
    {"local_language", "Capture local terms and sentiment"},
    {"negative_evidence", "Find criticism, backlash, failures, and blockers"}
  ]

  def plan(parsed_study, opts \\ %{}) do
    opts = Map.new(opts)
    region = Map.get(parsed_study, :region) || "global"
    language = Map.get(parsed_study, :language) || "en"
    context = "#{parsed_study.domain} #{parsed_study.target_audience} #{parsed_study.change}"
    private_entities = Map.get(opts, :private_entities, [])

    Enum.map(@lanes, fn {lane, purpose} ->
      intent = lane_query(lane, context, region)

      %{
        lane: lane,
        purpose: purpose,
        query_intent: intent,
        safe_query: QueryAbstractor.abstract(intent, private_entities: private_entities),
        region: region,
        language: language,
        freshness: freshness_for(lane),
        expected_simulation_impact: impact_for(lane)
      }
    end)
  end

  defp lane_query("market_context", context, region), do: "#{context} market context #{region}"

  defp lane_query("competitor_analogue", context, region),
    do: "#{context} similar launch examples #{region}"

  defp lane_query("behavioral_research", context, region),
    do: "#{context} adoption barriers behavioral research #{region}"

  defp lane_query("regulatory", context, region),
    do: "#{context} privacy data regulation #{region}"

  defp lane_query("recent_news", context, region), do: "#{context} recent news #{region}"

  defp lane_query("local_language", context, region),
    do: "#{context} user sentiment local terms #{region}"

  defp lane_query("negative_evidence", context, region),
    do: "#{context} criticism backlash failure complaints #{region}"

  defp freshness_for(lane) when lane in ["recent_news", "regulatory"], do: "recent"
  defp freshness_for(_lane), do: "standard"

  defp impact_for("negative_evidence"),
    do: "May reveal blockers or resistance patterns that lower adoption confidence."

  defp impact_for("regulatory"),
    do: "May constrain the scenario or introduce a policy-sensitive segment."

  defp impact_for("behavioral_research"),
    do: "May alter persona motivations, frictions, and action probabilities."

  defp impact_for(_lane),
    do: "May improve grounding for personas, patterns, and uncertainty estimates."
end
