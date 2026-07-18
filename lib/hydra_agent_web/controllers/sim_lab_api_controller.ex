defmodule HydraAgentWeb.SimLabApiController do
  use HydraAgentWeb, :controller

  alias HydraAgent.SimLab.{Simulations, Studies}

  def snapshots(conn, %{
        "workspace_id" => workspace_id,
        "study_id" => study_id,
        "run_id" => run_id
      }) do
    study = Studies.get_study!(workspace_id, study_id)
    run = Simulations.get_run!(study, run_id)

    json(conn, %{data: Enum.map(Simulations.replay_snapshots(run), &snapshot_json/1)})
  end

  def snapshot(conn, %{
        "workspace_id" => workspace_id,
        "study_id" => study_id,
        "run_id" => run_id,
        "tick" => tick
      }) do
    study = Studies.get_study!(workspace_id, study_id)
    run = Simulations.get_run!(study, run_id)

    case Enum.find(Simulations.replay_snapshots(run), &(&1.tick == parse_tick(tick))) do
      nil -> send_resp(conn, 404, "Not found")
      snapshot -> json(conn, %{data: snapshot_json(snapshot)})
    end
  end

  def cluster(conn, %{
        "workspace_id" => workspace_id,
        "study_id" => study_id,
        "run_id" => run_id,
        "cluster_id" => cluster_id
      }) do
    study = Studies.get_study!(workspace_id, study_id)
    run = Simulations.get_run!(study, run_id)

    cluster =
      run
      |> Simulations.replay_snapshots()
      |> Enum.flat_map(&(&1.clusters["groups"] || []))
      |> Enum.find(&((Map.get(&1, "id") || Map.get(&1, :id)) == cluster_id))

    case cluster do
      nil -> send_resp(conn, 404, "Not found")
      cluster -> json(conn, %{data: %{cluster: cluster, detail_level: "aggregate_cohort"}})
    end
  end

  def agent_trace(conn, %{
        "workspace_id" => workspace_id,
        "study_id" => study_id,
        "run_id" => run_id,
        "agent_id" => agent_id
      }) do
    study = Studies.get_study!(workspace_id, study_id)
    run = Simulations.get_run!(study, run_id)
    patterns = Simulations.patterns_for_run(run, Studies.list_action_patterns(study))

    case Simulations.representative_trace(run, agent_id, patterns) do
      {:ok, trace} -> json(conn, %{data: trace})
      {:error, :representative_agent_not_in_run} -> send_resp(conn, 404, "Not found")
    end
  end

  def compare(
        conn,
        %{
          "workspace_id" => workspace_id,
          "study_id" => study_id,
          "run_id" => run_id
        } = params
      ) do
    study = Studies.get_study!(workspace_id, study_id)
    variant_run_ids = variant_run_ids(params)

    case variant_run_ids do
      [] ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{reason: "missing_variant_run_id"}})

      ids ->
        comparisons = Enum.map(ids, &Simulations.compare_runs(study, run_id, &1))
        [first | _rest] = comparisons

        json(conn, %{
          data: %{
            base: run_json(first.base),
            comparisons:
              Enum.map(comparisons, fn comparison ->
                %{
                  variant: run_json(comparison.variant),
                  deltas: comparison.deltas,
                  recommendation: comparison.recommendation
                }
              end)
          }
        })
    end
  end

  defp snapshot_json(snapshot) do
    %{
      tick: snapshot.tick,
      label: snapshot.label,
      clusters: snapshot.clusters["groups"] || [],
      metrics: snapshot.metrics,
      decision_counts: snapshot.decision_counts,
      cost: snapshot.cost,
      insight_refs: snapshot.insight_refs
    }
  end

  defp parse_tick(tick) do
    case Integer.parse(to_string(tick)) do
      {value, _} -> value
      :error -> -1
    end
  end

  defp variant_run_ids(params) do
    params
    |> Map.get("variant_run_ids", Map.get(params, "variant_run_id", []))
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp run_json(run) do
    %{
      run_id: run.id,
      scenario_id: run.scenario_id,
      scenario_name: run.scenario.name,
      mode: run.mode,
      agent_count: run.agent_count,
      confidence: run.confidence,
      aggregate_metrics: run.aggregate_metrics,
      actual_cost_usd: decimal_json(run.actual_cost_usd)
    }
  end

  defp decimal_json(nil), do: nil
  defp decimal_json(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_json(value), do: value
end
