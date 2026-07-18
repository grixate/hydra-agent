defmodule HydraAgentWeb.SimLabApiControllerTest do
  use HydraAgentWeb.ConnCase, async: true

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.SimLab.{Demo, SimulationRunner, Simulations, Studies}

  test "serves only compact replay snapshots and aggregate cluster detail", %{conn: conn} do
    workspace = workspace_fixture()

    {:ok, study} =
      Studies.create_study(%{
        workspace_id: workspace.id,
        title: "Certificate visibility",
        question: "How will employees react to visible certificates?"
      })

    {:ok, %{context_pack: context_pack}} =
      Studies.add_manual_note(study, %{note: "Visibility controls are important."})

    {:ok, scenario} =
      Simulations.create_scenario(study, %{
        name: "Visibility default",
        description: "Certificates appear in profiles.",
        events: Demo.study().events
      })

    prepared =
      SimulationRunner.prepare(Demo.simulation_input(), study, mode: "small", confidence: 0.55)

    {:ok, %{run: run}} =
      Simulations.persist_prepared_run(study, scenario, context_pack, prepared)

    snapshots_path =
      "/api/v1/workspaces/#{workspace.id}/sim_lab/studies/#{study.id}/runs/#{run.id}/snapshots"

    snapshots = conn |> get(snapshots_path) |> json_response(200)
    assert length(snapshots["data"]) == 4

    assert [%{"clusters" => clusters, "decision_counts" => decision_counts} | _] =
             snapshots["data"]

    assert length(clusters) in 5..10
    assert Enum.sum_by(clusters, & &1["count"]) == Demo.simulation_input().agent_count
    assert decision_counts["pattern"] > 0
    assert decision_counts["small_model"] == 0

    cluster_id = hd(clusters)["id"]

    cluster =
      conn
      |> get(
        "/api/v1/workspaces/#{workspace.id}/sim_lab/studies/#{study.id}/runs/#{run.id}/clusters/#{cluster_id}"
      )
      |> json_response(200)

    assert cluster["data"]["detail_level"] == "aggregate_cohort"
    assert cluster["data"]["cluster"]["id"] == cluster_id

    representative_agent_id = hd(clusters)["representative_agent_id"]

    trace =
      conn
      |> get(
        "/api/v1/workspaces/#{workspace.id}/sim_lab/studies/#{study.id}/runs/#{run.id}/agents/#{representative_agent_id}/trace"
      )
      |> json_response(200)

    assert trace["data"]["detail_level"] == "representative_cohort_trace"
    assert trace["data"]["representation"] == "deterministic_cohort_sample"
    assert trace["data"]["llm_fallback_used"] == false
    assert length(trace["data"]["trace"]) == 4

    conn
    |> get(
      "/api/v1/workspaces/#{workspace.id}/sim_lab/studies/#{study.id}/runs/#{run.id}/agents/not-a-representative/trace"
    )
    |> response(404)

    {:ok, variant} = Simulations.create_variant(study, scenario)

    {:ok, %{run: variant_run}} =
      Simulations.persist_prepared_run(study, variant, context_pack, prepared)

    comparison =
      conn
      |> get(
        "/api/v1/workspaces/#{workspace.id}/sim_lab/studies/#{study.id}/runs/#{run.id}/compare?variant_run_ids[]=#{variant_run.id}"
      )
      |> json_response(200)

    assert comparison["data"]["base"]["run_id"] == run.id

    assert [%{"variant" => variant_data, "deltas" => deltas, "recommendation" => recommendation}] =
             comparison["data"]["comparisons"]

    assert variant_data["run_id"] == variant_run.id
    assert Map.has_key?(deltas, "adopt")
    assert recommendation["label"]

    missing_variant =
      conn
      |> get(
        "/api/v1/workspaces/#{workspace.id}/sim_lab/studies/#{study.id}/runs/#{run.id}/compare"
      )
      |> json_response(400)

    assert missing_variant["errors"]["reason"] == "missing_variant_run_id"
  end
end
