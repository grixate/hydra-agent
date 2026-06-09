defmodule HydraAgent.Simulation.ScenarioTemplates do
  @moduledoc """
  Neutral scenario presets for simulation world generation.
  """

  @templates %{
    "product_rollout" => %{
      "label" => "Product rollout",
      "event_types" => [
        :product_launch,
        :market_shift,
        :competitor_move,
        :partnership_offer,
        :demand_surge,
        :pr_crisis
      ],
      "world" => %{
        "market" => %{"momentum" => 0.5, "volatility" => 0.4},
        "resources" => %{"capacity" => 0.7},
        "sentiment" => %{"customers" => 0.55, "team" => 0.6},
        "risks" => [],
        "open_threads" => [],
        "resolved_threads" => []
      }
    },
    "incident_response" => %{
      "label" => "Incident response",
      "event_types" => [:security_breach, :pr_crisis, :budget_pressure, :conflict_escalation],
      "world" => %{
        "market" => %{"momentum" => 0.35, "volatility" => 0.8},
        "resources" => %{"capacity" => 0.45},
        "sentiment" => %{"customers" => 0.35, "team" => 0.5},
        "risks" => ["service trust"],
        "open_threads" => ["triage"],
        "resolved_threads" => []
      }
    },
    "market_shock" => %{
      "label" => "Market shock",
      "event_types" => [:market_crash, :market_shift, :competitor_move, :budget_pressure],
      "world" => %{
        "market" => %{"momentum" => 0.25, "volatility" => 0.9},
        "resources" => %{"capacity" => 0.55},
        "sentiment" => %{"customers" => 0.45, "team" => 0.48},
        "risks" => ["demand volatility"],
        "open_threads" => ["pricing"],
        "resolved_threads" => []
      }
    },
    "negotiation" => %{
      "label" => "Negotiation",
      "event_types" => [:partnership_offer, :conflict_escalation, :competitor_move],
      "world" => %{
        "market" => %{"momentum" => 0.55, "volatility" => 0.5},
        "resources" => %{"capacity" => 0.65},
        "sentiment" => %{"customers" => 0.52, "team" => 0.58},
        "risks" => ["alignment"],
        "open_threads" => ["terms"],
        "resolved_threads" => []
      }
    },
    "support_surge" => %{
      "label" => "Customer support surge",
      "event_types" => [:demand_surge, :budget_pressure, :pr_crisis, :product_launch],
      "world" => %{
        "market" => %{"momentum" => 0.65, "volatility" => 0.6},
        "resources" => %{"capacity" => 0.4},
        "sentiment" => %{"customers" => 0.42, "team" => 0.46},
        "risks" => ["response backlog"],
        "open_threads" => ["support load"],
        "resolved_threads" => []
      }
    }
  }

  def all, do: @templates

  def get(name), do: Map.get(@templates, to_string(name), @templates["product_rollout"])

  def event_types(name), do: get(name)["event_types"]

  def initial_world(name), do: get(name)["world"]
end
