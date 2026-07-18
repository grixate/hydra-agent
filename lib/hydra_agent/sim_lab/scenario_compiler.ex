defmodule HydraAgent.SimLab.ScenarioCompiler do
  @moduledoc """
  Builds a conservative, editable scenario portfolio from a saved study brief.

  The compiler never invents numeric effects. It creates a baseline and two
  clearly labelled counterfactual shells whose timelines must be reviewed
  before a run. This keeps scenario generation useful without smuggling causal
  assumptions into the simulator.
  """

  alias HydraAgent.SimLab.Research.StudyParser

  @protocol_version "sim-lab-scenario-compiler/v1"
  @actions ~w(adopt resist ignore share)

  def compile(study, context_pack \\ nil) do
    parsed =
      StudyParser.parse(study.question, %{
        domain: study.domain,
        region: study.region,
        language: study.language,
        target_audience: study.target_audience
      })

    audience = study.target_audience || parsed.target_audience || "target audience"
    domain = study.domain || parsed.domain || "the study context"
    horizon = study.timeframe || "90 days"
    base_name = concise_title(study.title || "Study")
    shared = shared_attrs(study, context_pack, audience, domain, horizon, parsed)

    %{
      base:
        Map.merge(shared, %{
          name: "#{base_name} · Baseline",
          description: study.question,
          events: baseline_events(audience, domain, parsed.change),
          metadata:
            metadata(context_pack, "baseline", [
              "The saved brief accurately describes the change under study."
            ])
        }),
      variants: [
        Map.merge(shared, %{
          name: "#{base_name} · Control first",
          description:
            "Counterfactual: introduce #{parsed.change} with explicit choice, preview, and reversibility.",
          events: control_events(audience, parsed.change),
          metadata:
            metadata(context_pack, "control_first", [
              "Explicit choice and reversibility may change resistance; no numeric effect is assumed."
            ])
        }),
        Map.merge(shared, %{
          name: "#{base_name} · Proof first",
          description:
            "Counterfactual: show credible proof and a trusted example before asking people to respond to #{parsed.change}.",
          events: proof_events(audience, parsed.change),
          metadata:
            metadata(context_pack, "proof_first", [
              "Trusted proof may change waiting or adoption; no numeric effect is assumed."
            ])
        })
      ]
    }
  end

  defp shared_attrs(study, context_pack, audience, domain, horizon, parsed) do
    %{
      forecast_horizon: horizon,
      available_actions: @actions,
      success_metrics: [
        "Observed adoption, resistance, waiting, and sharing among #{audience}",
        "Change from baseline by the end of #{horizon}"
      ],
      constraints: constraints(study, context_pack, domain, parsed)
    }
  end

  defp constraints(study, context_pack, domain, parsed) do
    base = [
      "Directional aggregate model; not causal proof.",
      "No event changes a probability until a researcher adds an explicit effect.",
      "Scope: #{domain}; region: #{study.region || parsed.region || "not specified"}."
    ]

    if context_pack do
      base ++ ["Context pack v#{context_pack.version}; confidence must remain visible."]
    else
      base ++ ["No active context pack; treat every behavioral effect as an assumption."]
    end
  end

  defp baseline_events(audience, domain, change) do
    [
      event(1, "Change introduced", "#{audience} first learn about #{change}."),
      event(14, "First meaningful exposure", "Early response becomes observable in #{domain}."),
      event(30, "Signals settle", "Value, trust, and control signals become easier to evaluate.")
    ]
  end

  defp control_events(audience, change) do
    [
      event(
        1,
        "Choice explained",
        "#{audience} see the purpose, preview, and controls for #{change}."
      ),
      event(14, "Voluntary first use", "People can try the change without losing reversibility."),
      event(30, "Control reviewed", "Opt-in, opt-out, and support signals are inspected.")
    ]
  end

  defp proof_events(audience, change) do
    [
      event(1, "Evidence shared", "#{audience} see a credible example before #{change}."),
      event(
        14,
        "Trusted example",
        "A relevant peer or expert demonstrates an observable outcome."
      ),
      event(30, "Proof reviewed", "Claims are compared with actual use and remaining friction.")
    ]
  end

  defp event(day, title, impact) do
    %{
      "day" => day,
      "title" => title,
      "impact" => impact,
      "action_effects" => %{}
    }
  end

  defp metadata(context_pack, variant, assumptions) do
    %{
      "created_in" => "scenario_compiler",
      "generated_by_protocol_version" => @protocol_version,
      "variant_hypothesis" => variant,
      "assumptions" => assumptions,
      "numeric_effects" => "none_until_researcher_review",
      "context_pack_id" => context_pack && context_pack.id,
      "context_pack_version" => context_pack && context_pack.version,
      "context_confidence" => context_pack && context_pack.confidence
    }
  end

  defp concise_title(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 72)
  end
end
