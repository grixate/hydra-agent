defmodule HydraAgent.Simulations.Engine.Snapshotter do
  @moduledoc "Builds and verifies content-addressed run snapshots."
  use GenServer

  alias HydraAgent.Simulations.ContentHash

  def start_link(opts) do
    run_record_id = Keyword.fetch!(opts, :run_record_id)
    GenServer.start_link(__MODULE__, %{}, name: name(run_record_id))
  end

  def name(run_record_id),
    do: {:via, Registry, {HydraAgent.ProcessRegistry, {:simulation_snapshotter, run_record_id}}}

  def build(run_record_id, payload),
    do: GenServer.call(name(run_record_id), {:build, payload}, :infinity)

  def verify(run_record_id, payload, checksum),
    do: GenServer.call(name(run_record_id), {:verify, payload, checksum}, :infinity)

  @doc "Verifies a snapshot payload without requiring a live run process."
  def verify_payload(payload, checksum) when is_map(payload) and is_binary(checksum) do
    state_hash = authoritative_state_hash(payload)
    expected = ContentHash.digest(%{"payload" => payload, "state_hash" => state_hash})

    if expected == checksum, do: {:ok, state_hash}, else: {:error, :checksum_mismatch}
  end

  def verify_payload(_payload, _checksum), do: {:error, :invalid_snapshot_payload}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:build, payload}, _from, state) do
    state_hash = authoritative_state_hash(payload)
    checksum = ContentHash.digest(%{"payload" => payload, "state_hash" => state_hash})
    {:reply, %{payload: payload, state_hash: state_hash, checksum: checksum}, state}
  end

  def handle_call({:verify, payload, checksum}, _from, state) do
    {:reply, verify_payload(payload, checksum), state}
  end

  defp authoritative_state_hash(payload) do
    payload
    |> Map.take([
      "round",
      "world",
      "agents",
      "relationships",
      "balances",
      "action_counts",
      "observations",
      "unchanged_rounds"
    ])
    |> ContentHash.digest()
  end
end
