defmodule HydraAgent.Simulations.Engine.BalancedCognition do
  @moduledoc """
  Bounded model escalation for Balanced simulation rounds.

  Routine behavior remains deterministic. This module groups eligible agents by
  a stable policy signature, selects a small set of representative decisions,
  validates the strict decision contract, and records the result before the
  deterministic engine applies it. A retry reuses the immutable round records.
  """

  import Ecto.Query
  require Logger

  alias HydraAgent.{Providers, Repo}

  alias HydraAgent.Simulations.{
    BudgetGovernor,
    BudgetReservation,
    ContentHash,
    RunDecision,
    RunDecisionAgent,
    SimulationRunRecord
  }

  @contract_keys MapSet.new(
                   ~w(action_id parameters reason_codes short_rationale memory_updates uncertainty)
                 )
  @default_input_envelope 1_400
  @default_output_envelope 300
  @signature_version "hydra-policy-signature/v1"

  def prepare_round(%SimulationRunRecord{mode: "quick"}, _state, _round), do: {:ok, %{}}

  def prepare_round(%SimulationRunRecord{} = record, state, round)
      when is_map(state) and is_integer(round) do
    :ok = reconcile_interrupted_requests(record, state, round)
    existing = decisions_for_round(record.id, round)

    cond do
      existing != [] ->
        {:ok, overrides(existing)}

      record.replay_kind == "exact_replay" ->
        replay_round(record, state, round)

      record.mode == "balanced" ->
        decide_round(record, state, round)

      true ->
        {:ok, %{}}
    end
  rescue
    error in Ecto.InvalidChangesetError ->
      changeset = error.changeset
      errors = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
      Logger.error("balanced cognition record rejected: #{inspect(errors)}")
      {:error, {:balanced_cognition_invalid_record, errors}}

    error ->
      Logger.error("balanced cognition stopped safely: #{Exception.message(error)}")
      {:error, {:balanced_cognition_exception, error.__struct__}}
  end

  def default_policy(%{stage_caps: stage_caps, max_concurrency: concurrency}, type_ids) do
    global = max(get_in(stage_caps, ["simulation", "calls"]) || 0, 0)

    per_type =
      if type_ids == [], do: 0, else: max(div(global + length(type_ids) - 1, length(type_ids)), 1)

    %{
      "global_model_decisions" => global,
      "per_round" => min(12, global),
      "per_agent_type" => Map.new(type_ids, &{&1, per_type}),
      "per_agent_max" => 2,
      "max_concurrency" => min(max(concurrency || 1, 1), 16),
      "minimum_priority" => 0.42,
      "max_input_tokens" => @default_input_envelope,
      "max_output_tokens" => @default_output_envelope,
      "signature_version" => @signature_version,
      "activation_signals" =>
        ~w(novelty uncertainty influence downstream_impact deterministic_disagreement user_importance representative_sampling cache_miss)
    }
  end

  def list_decisions(run_record_id) do
    RunDecision
    |> where([decision], decision.simulation_run_record_id == ^run_record_id)
    |> order_by([decision], asc: decision.sequence)
    |> preload(:agents)
    |> Repo.all()
  end

  def list_recent_decisions(run_record_id, limit \\ 6) do
    RunDecision
    |> where([decision], decision.simulation_run_record_id == ^run_record_id)
    |> order_by([decision], desc: decision.sequence)
    |> limit(^limit)
    |> Repo.all()
  end

  def summary(run_record_id) do
    {decisions, model, reused, fallbacks} =
      RunDecision
      |> where([decision], decision.simulation_run_record_id == ^run_record_id)
      |> select([decision], {
        count(decision.id),
        fragment("COUNT(*) FILTER (WHERE ? = 'model')", decision.source),
        fragment(
          "COUNT(*) FILTER (WHERE ? IN ('policy_signature_cache','exact_replay'))",
          decision.source
        ),
        fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", decision.fallback)
      })
      |> Repo.one()

    affected_agents =
      RunDecisionAgent
      |> where([mapping], mapping.simulation_run_record_id == ^run_record_id)
      |> select([mapping], count(mapping.agent_id, :distinct))
      |> Repo.one()

    %{
      "decisions" => decisions,
      "model_decisions" => model,
      "reused_decisions" => reused,
      "fallback_decisions" => fallbacks,
      "affected_agents" => affected_agents
    }
  end

  def manifest_hash(run_record_id) do
    run_record_id
    |> list_decisions()
    |> Enum.map(fn decision ->
      %{
        "round" => decision.round,
        "policy_signature" => decision.policy_signature,
        "action_id" => decision.action_id,
        "parameters" => decision.parameters,
        "reason_codes" => decision.reason_codes,
        "short_rationale" => decision.short_rationale,
        "uncertainty" => decimal_string(decision.uncertainty),
        "agents" => decision.agents |> Enum.map(& &1.agent_id) |> Enum.sort()
      }
    end)
    |> ContentHash.digest()
  end

  defp decide_round(record, state, round) do
    record = Repo.preload(record, [:budget_plan, :simulation_script], in_parallel: false)
    policy = record.decision_policy || %{}
    groups = policy_groups(record, state, round)
    prior_by_signature = prior_decisions(record.id)
    mapping_counts = agent_mapping_counts(record.id)
    model_counts = model_counts_by_type(record.id)

    {cached, uncached} = Enum.split_with(groups, &Map.has_key?(prior_by_signature, &1.signature))

    cached =
      cached
      |> eligible_groups(mapping_counts, policy)
      |> Enum.map(fn group ->
        Map.put(group, :cached_decision, prior_by_signature[group.signature])
      end)

    selected =
      uncached
      |> eligible_groups(mapping_counts, policy)
      |> select_groups(record, policy, model_counts)

    cached_decisions =
      Enum.map(cached, &persist_cached_decision(record, round, &1, &1.cached_decision))

    model_decisions = call_and_persist(record, round, selected, policy)

    case collect_results(cached_decisions ++ model_decisions) do
      {:ok, decisions} -> {:ok, overrides(decisions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_round(record, state, round) do
    source = decisions_for_round(record.replay_source_id, round)
    current_ids = MapSet.new(state["agents"] || [], & &1["id"])

    results =
      Enum.map(source, fn decision ->
        agents = Enum.filter(decision.agents, &MapSet.member?(current_ids, &1.agent_id))
        persist_replay_decision(record, decision, agents)
      end)

    collect_results(results)
    |> case do
      {:ok, decisions} -> {:ok, overrides(decisions)}
      error -> error
    end
  end

  defp reconcile_interrupted_requests(
         %{mode: "balanced", replay_kind: replay_kind} = record,
         state,
         round
       )
       when replay_kind in ~w(original fresh_rerun) do
    reservations =
      BudgetReservation
      |> where(
        [reservation],
        reservation.simulation_run_record_id == ^record.id and
          reservation.stage == "simulation" and reservation.kind == "provider_call" and
          reservation.status == "reserved"
      )
      |> Repo.all()

    if reservations != [] do
      record = Repo.preload(record, :simulation_script, in_parallel: false)

      groups =
        record
        |> policy_groups(state, round)
        |> Map.new(&{decision_key(record, round, &1.signature), &1})

      Enum.each(reservations, fn reservation ->
        case groups[reservation.idempotency_key] do
          nil ->
            {:ok, _closed} = BudgetGovernor.fail(reservation, :interrupted_provider_request)

          group ->
            case persist_provider_decision(record, round, group, %{
                   status: :provider_exception,
                   failure: :interrupted_provider_request
                 }) do
              {:ok, _decision} ->
                :ok

              {:error, reason} ->
                raise "could not reconcile interrupted decision: #{inspect(reason)}"
            end
        end
      end)
    end

    :ok
  end

  defp reconcile_interrupted_requests(_record, _state, _round), do: :ok

  defp policy_groups(record, state, round) do
    script = record.simulation_script.script
    assignments = Map.new(script["agent_types"] || [], &{&1["id"], &1["policy"]})
    policies = Map.new(script["policies"] || [], &{&1["id"], &1})
    degrees = relationship_degrees(state["relationships"] || [])
    population_size = max(length(state["agents"] || []), 1)

    state["agents"]
    |> Enum.sort_by(& &1["id"])
    |> Enum.flat_map(fn agent ->
      policy_id = assignments[agent["type"]]

      case policies[policy_id] do
        %{"kind" => "hybrid"} = hybrid ->
          payload = signature_payload(record, state, agent, hybrid, degrees)
          signature = ContentHash.digest(payload)
          [{signature, policy_id, hybrid, agent, payload}]

        _policy ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {signature, members} ->
      {_signature, policy_id, hybrid, _agent, signature_payload} = hd(members)
      agents = members |> Enum.map(&elem(&1, 3)) |> Enum.sort_by(& &1["id"])
      representative = hd(agents)
      score = score_group(record, state, round, agents, hybrid, population_size)

      %{
        signature: signature,
        signature_payload: signature_payload,
        policy_id: policy_id,
        hybrid: hybrid,
        agents: agents,
        representative: representative,
        score: score.total,
        score_components: score.components
      }
    end)
    |> Enum.sort_by(&{-&1.score, &1.signature})
  end

  defp signature_payload(record, state, agent, hybrid, degrees) do
    %{
      "version" => record.decision_policy["signature_version"] || @signature_version,
      "agent_type" => agent["type"],
      "archetype" => agent["archetype"],
      "policy_id" => hybrid["id"],
      "allowed_actions" => Enum.sort(hybrid["candidates"] || []),
      "attributes" => bucket_map(agent["attributes"] || %{}),
      "resources" => bucket_map(agent["resources"] || %{}),
      "state" => bucket_map(agent["state"] || %{}),
      "world" => bucket_map(state["world"] || %{}),
      "recent_event_types" =>
        state
        |> Map.get("recent_events", [])
        |> Enum.map(&(&1["id"] || &1["type"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(12),
      "relationship_class" => degree_class(degrees[agent["id"]] || 0),
      "script_version" => record.simulation_script.content_hash,
      "route_version" => get_in(record.model_route_snapshot, ["simulation", "route_version"])
    }
  end

  defp score_group(record, state, round, agents, hybrid, population_size) do
    clarity = number(get_in(state, ["world", "information_clarity"]), 0.5)
    uncertainty = clamp(1.0 - clarity)
    influence = clamp(:math.log(length(agents) + 1) / :math.log(population_size + 1))
    rounds = max(record.rounds_planned, 1)
    downstream = clamp(1.0 - (round - 1) / rounds)
    disagreement = if length(hybrid["candidates"] || []) > 1, do: 0.7, else: 0.2
    importance = representative_importance(hd(agents))

    components = %{
      "novelty" => 1.0,
      "uncertainty" => uncertainty,
      "influence" => influence,
      "downstream_impact" => downstream,
      "deterministic_disagreement" => disagreement,
      "user_importance" => importance,
      "representative_sampling" => 0.7,
      "cache_miss" => 1.0
    }

    total =
      0.18 + uncertainty * 0.18 + influence * 0.14 + downstream * 0.12 +
        disagreement * 0.14 + importance * 0.1 + 0.07 + 0.07

    %{total: clamp(total), components: Map.new(components, fn {k, v} -> {k, rounded(v)} end)}
  end

  defp eligible_groups(groups, counts, policy) do
    max_per_agent = max(integer(policy["per_agent_max"], 2), 1)

    groups
    |> Enum.map(fn group ->
      agents = Enum.filter(group.agents, &(Map.get(counts, &1["id"], 0) < max_per_agent))
      if agents == [], do: nil, else: %{group | agents: agents, representative: hd(agents)}
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp select_groups(groups, record, policy, model_counts) do
    budget = BudgetGovernor.summary(record.budget_plan, simulation_run_record_id: record.id)
    remaining = budget["remaining_model_calls"] || 0
    global = max(integer(policy["global_model_decisions"], 0) - budget["model_calls"], 0)
    limit = min(min(integer(policy["per_round"], 0), global), remaining)
    threshold = number(policy["minimum_priority"], 0.42)
    per_type = policy["per_agent_type"] || %{}

    groups
    |> Enum.filter(&(&1.score >= threshold))
    |> Enum.reduce({[], model_counts}, fn group, {selected, counts} ->
      type = group.representative["type"]
      type_cap = integer(per_type[type], global)

      if length(selected) < limit and Map.get(counts, type, 0) < type_cap do
        {[group | selected], Map.update(counts, type, 1, &(&1 + 1))}
      else
        {selected, counts}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp call_and_persist(_record, _round, [], _policy), do: []

  defp call_and_persist(record, round, groups, policy) do
    max_concurrency = min(max(integer(policy["max_concurrency"], 1), 1), length(groups))

    groups
    |> Enum.chunk_every(max_concurrency)
    |> Enum.flat_map(fn batch ->
      batch
      |> Task.async_stream(
        &call_provider(record, round, &1, policy),
        ordered: true,
        max_concurrency: max_concurrency,
        timeout: provider_timeout(record),
        on_timeout: :kill_task
      )
      |> Enum.zip(batch)
      |> Enum.map(fn
        {{:ok, result}, group} ->
          persist_provider_decision(record, round, group, result)

        {{:exit, _reason}, group} ->
          persist_provider_decision(record, round, group, %{status: :timeout})
      end)
    end)
  end

  defp call_provider(record, round, group, policy) do
    route = get_in(record.model_route_snapshot, ["simulation"]) || %{}
    provider = route["name"] && Providers.get_config_by_name(record.workspace_id, route["name"])

    if is_nil(provider) do
      %{status: :route_unavailable}
    else
      prompt = prompt_snapshot(record, round, group)
      decision_key = decision_key(record, round, group.signature)

      request = %{
        "kind" => "provider_call",
        "provider" => route["provider"],
        "model" => route["model"],
        "max_input_tokens" => integer(policy["max_input_tokens"], @default_input_envelope),
        "max_output_tokens" => integer(policy["max_output_tokens"], @default_output_envelope),
        "idempotency_key" => decision_key,
        "metadata" => %{"decision_key" => decision_key, "policy_signature" => group.signature}
      }

      case BudgetGovernor.reserve(record.budget_plan, "simulation", request,
             on_exhaustion: :fallback,
             simulation_run_record_id: record.id,
             elapsed_runtime_seconds: elapsed_seconds(record)
           ) do
        {:ok, reservation} ->
          provider_request = provider_request(record, route, prompt, group, decision_key)

          case Providers.chat(provider, provider_request) do
            {:ok, response} ->
              case parse_decision(response, group.hybrid["candidates"] || []) do
                {:ok, decision} ->
                  %{
                    status: :valid,
                    reservation: reservation,
                    decision: decision,
                    response: response
                  }

                {:error, reason} ->
                  %{status: :invalid, reservation: reservation, failure: reason}
              end

            {:error, error} ->
              %{status: :provider_error, reservation: reservation, failure: error}
          end

        {:fallback, reservation} ->
          %{status: :budget_fallback, reservation: reservation}

        {:error, error} ->
          %{status: :budget_error, failure: error}
      end
    end
  rescue
    error -> %{status: :provider_exception, failure: error.__struct__}
  end

  defp provider_request(record, route, prompt, group, decision_key) do
    %{
      "model" => route["model"],
      "temperature" => 0,
      "messages" => [
        %{
          "role" => "system",
          "content" =>
            "Return one JSON object only. Choose one allowed action. Do not add keys or prose."
        },
        %{"role" => "user", "content" => Jason.encode!(prompt)}
      ],
      "metadata" => %{
        "hydra_simulation_decision" => true,
        "decision_key" => decision_key,
        "allowed_actions" => Enum.sort(group.hybrid["candidates"] || []),
        "run_pack_hash" => record.pack_hash
      }
    }
  end

  defp prompt_snapshot(record, round, group) do
    representative = group.representative

    %{
      "contract" => %{
        "action_id" => "allowed action id",
        "parameters" => %{},
        "reason_codes" => ["short_machine_reason"],
        "short_rationale" => "500 characters or fewer",
        "memory_updates" => %{},
        "uncertainty" => "number from 0 to 1"
      },
      "round" => round,
      "rounds_planned" => record.rounds_planned,
      "policy_signature" => group.signature,
      "agent_type" => representative["type"],
      "archetype" => representative["archetype"],
      "representative" => %{
        "attributes" => representative["attributes"] || %{},
        "resources" => representative["resources"] || %{},
        "state" => representative["state"] || %{},
        "goals" => representative["goals"] || [],
        "constraints" => representative["constraints"] || []
      },
      "signature_context" => group.signature_payload,
      "allowed_actions" => Enum.sort(group.hybrid["candidates"] || []),
      "affected_agent_count" => length(group.agents)
    }
  end

  defp parse_decision(response, allowed_actions) do
    content = get_in(response, ["message", "content"])

    with true <- is_binary(content),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded),
         true <- MapSet.new(Map.keys(decoded)) == @contract_keys,
         action when is_binary(action) <- decoded["action_id"],
         true <- action in allowed_actions,
         parameters when is_map(parameters) <- decoded["parameters"],
         true <- bounded_json?(parameters),
         codes when is_list(codes) <- decoded["reason_codes"],
         true <- length(codes) <= 12 and Enum.all?(codes, &valid_reason_code?/1),
         rationale when is_binary(rationale) <- decoded["short_rationale"],
         true <- String.length(rationale) in 1..500,
         memory when is_map(memory) <- decoded["memory_updates"],
         true <- bounded_memory?(memory),
         uncertainty when is_number(uncertainty) <- decoded["uncertainty"],
         true <- uncertainty >= 0 and uncertainty <= 1 do
      {:ok, decoded}
    else
      _invalid -> {:error, :invalid_decision_contract}
    end
  end

  defp persist_provider_decision(record, round, group, %{status: :valid} = result) do
    usage = stringify_map(result.response["usage"] || %{})

    persist_decision(record, round, group, fn ->
      case BudgetGovernor.complete(result.reservation, usage) do
        {:ok, reservation} ->
          {result.decision, "model", nil, reservation, provider_metadata(result.response)}

        {:error, reason} ->
          {:ok, reservation} = BudgetGovernor.fail(result.reservation, reason)

          {fallback_contract(group, "invalid_provider_usage"), "deterministic_rule",
           "deterministic_rule", reservation, %{"failure" => "invalid_provider_usage"}}
      end
    end)
  end

  defp persist_provider_decision(record, round, group, result) do
    persist_decision(record, round, group, fn ->
      reservation = close_failed_reservation(record, round, group, result)
      reason = fallback_reason(result.status)

      {fallback_contract(group, reason), "deterministic_rule", "deterministic_rule", reservation,
       %{"failure" => reason}}
    end)
  end

  defp close_failed_reservation(
         _record,
         _round,
         _group,
         %{status: status, reservation: reservation, failure: failure}
       )
       when status in [:invalid, :provider_error] do
    {:ok, reservation} = BudgetGovernor.fail(reservation, failure)
    reservation
  end

  defp close_failed_reservation(
         _record,
         _round,
         _group,
         %{status: :budget_fallback, reservation: reservation}
       ),
       do: reservation

  defp close_failed_reservation(record, round, group, %{status: status})
       when status in [:timeout, :provider_exception] do
    reservation =
      Repo.get_by(BudgetReservation,
        budget_plan_id: record.budget_plan_id,
        idempotency_key: decision_key(record, round, group.signature)
      )

    case reservation do
      %BudgetReservation{status: "reserved"} ->
        {:ok, closed} = BudgetGovernor.fail(reservation, status)
        closed

      other ->
        other
    end
  end

  defp close_failed_reservation(_record, _round, _group, _result), do: nil

  defp persist_decision(record, round, group, resolver) do
    Repo.transaction(fn ->
      {contract, source, fallback, reservation, metadata} = resolver.()
      prompt = prompt_snapshot(record, round, group)
      route = get_in(record.model_route_snapshot, ["simulation"]) || %{}

      attrs = %{
        workspace_id: record.workspace_id,
        simulation_run_record_id: record.id,
        budget_reservation_id: reservation && reservation.id,
        decision_key: decision_key(record, round, group.signature),
        sequence: next_sequence(record.id),
        round: round,
        policy_id: group.policy_id,
        agent_type: group.representative["type"],
        archetype: group.representative["archetype"],
        representative_agent_id: group.representative["id"],
        policy_signature: group.signature,
        input_hash: ContentHash.digest(prompt),
        prompt_snapshot: prompt,
        output: contract,
        action_id: contract["action_id"],
        parameters: contract["parameters"],
        reason_codes: contract["reason_codes"],
        short_rationale: contract["short_rationale"],
        uncertainty: contract["uncertainty"],
        priority_score: rounded(group.score),
        score_components: group.score_components,
        source: source,
        provider: if(source == "model", do: route["provider"]),
        model: if(source == "model", do: route["model"]),
        model_route_version: route["route_version"],
        affected_agent_count: length(group.agents),
        reused_count: max(length(group.agents) - 1, 0),
        fallback: fallback,
        input_tokens: usage_value(reservation, :actual_input_tokens),
        output_tokens: usage_value(reservation, :actual_output_tokens),
        cost: reservation && reservation.actual_cost,
        metadata: metadata
      }

      decision = %RunDecision{} |> RunDecision.changeset(attrs) |> Repo.insert!()
      insert_agents!(record, decision, group.agents, "signature")
      Repo.preload(decision, :agents, in_parallel: false)
    end)
    |> transaction_result()
  end

  defp persist_cached_decision(record, round, group, cached) do
    Repo.transaction(fn ->
      attrs =
        clone_attrs(record, cached, %{
          replay_source_decision_id: cached.id,
          decision_key: decision_key(record, round, group.signature),
          sequence: next_sequence(record.id),
          round: round,
          representative_agent_id: group.representative["id"],
          affected_agent_count: length(group.agents),
          reused_count: length(group.agents),
          source: "policy_signature_cache",
          provider: nil,
          model: nil,
          input_tokens: 0,
          output_tokens: 0,
          cost: nil,
          metadata: %{"cache_source_round" => cached.round}
        })

      decision = %RunDecision{} |> RunDecision.changeset(attrs) |> Repo.insert!()
      insert_agents!(record, decision, group.agents, "signature")
      Repo.preload(decision, :agents, in_parallel: false)
    end)
    |> transaction_result()
  end

  defp persist_replay_decision(record, source, agents) do
    Repo.transaction(fn ->
      attrs =
        clone_attrs(record, source, %{
          replay_source_decision_id: source.id,
          decision_key: source.decision_key,
          sequence: source.sequence,
          source: "exact_replay",
          provider: nil,
          model: nil,
          affected_agent_count: length(agents),
          reused_count: length(agents),
          input_tokens: 0,
          output_tokens: 0,
          cost: nil,
          metadata: %{"source_run_record_id" => source.simulation_run_record_id}
        })

      decision = %RunDecision{} |> RunDecision.changeset(attrs) |> Repo.insert!()
      insert_replay_agents!(record, decision, agents)
      Repo.preload(decision, :agents, in_parallel: false)
    end)
    |> transaction_result()
  end

  defp clone_attrs(record, source, overrides) do
    %{
      workspace_id: record.workspace_id,
      simulation_run_record_id: record.id,
      decision_key: source.decision_key,
      sequence: source.sequence,
      round: source.round,
      policy_id: source.policy_id,
      agent_type: source.agent_type,
      archetype: source.archetype,
      representative_agent_id: source.representative_agent_id,
      policy_signature: source.policy_signature,
      input_hash: source.input_hash,
      prompt_snapshot: source.prompt_snapshot,
      output: source.output,
      action_id: source.action_id,
      parameters: source.parameters,
      reason_codes: source.reason_codes,
      short_rationale: source.short_rationale,
      uncertainty: source.uncertainty,
      priority_score: source.priority_score,
      score_components: source.score_components,
      source: source.source,
      provider: source.provider,
      model: source.model,
      model_route_version: source.model_route_version,
      affected_agent_count: source.affected_agent_count,
      reused_count: source.reused_count,
      fallback: source.fallback,
      input_tokens: source.input_tokens,
      output_tokens: source.output_tokens,
      cost: source.cost,
      metadata: source.metadata
    }
    |> Map.merge(overrides)
  end

  defp insert_agents!(record, decision, agents, reused_kind) do
    inserted_at = DateTime.utc_now()

    rows =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, index} ->
        %{
          workspace_id: record.workspace_id,
          simulation_run_record_id: record.id,
          simulation_run_decision_id: decision.id,
          round: decision.round,
          agent_id: agent["id"],
          agent_type: agent["type"],
          archetype: agent["archetype"],
          reuse_kind: if(index == 0, do: "representative", else: reused_kind),
          inserted_at: inserted_at
        }
      end)

    {_count, nil} = Repo.insert_all(RunDecisionAgent, rows)
  end

  defp insert_replay_agents!(record, decision, agents) do
    inserted_at = DateTime.utc_now()

    rows =
      Enum.map(agents, fn agent ->
        %{
          workspace_id: record.workspace_id,
          simulation_run_record_id: record.id,
          simulation_run_decision_id: decision.id,
          round: decision.round,
          agent_id: agent.agent_id,
          agent_type: agent.agent_type,
          archetype: agent.archetype,
          reuse_kind: "replay",
          inserted_at: inserted_at
        }
      end)

    {_count, nil} = Repo.insert_all(RunDecisionAgent, rows)
  end

  defp overrides(decisions) do
    Enum.reduce(decisions, %{}, fn decision, overrides ->
      value = %{
        "action_id" => decision.action_id,
        "parameters" => decision.parameters,
        "memory_updates" => decision.output["memory_updates"] || %{},
        "decision_id" => decision.id,
        "source" => decision.source
      }

      Enum.reduce(decision.agents, overrides, &Map.put(&2, &1.agent_id, value))
    end)
  end

  defp prior_decisions(run_record_id) do
    RunDecision
    |> where([decision], decision.simulation_run_record_id == ^run_record_id)
    |> order_by([decision], asc: decision.sequence)
    |> Repo.all()
    |> Enum.reduce(%{}, &Map.put_new(&2, &1.policy_signature, &1))
  end

  defp decisions_for_round(run_record_id, round) do
    RunDecision
    |> where(
      [decision],
      decision.simulation_run_record_id == ^run_record_id and decision.round == ^round
    )
    |> order_by([decision], asc: decision.sequence)
    |> preload(:agents)
    |> Repo.all()
  end

  defp agent_mapping_counts(run_record_id) do
    RunDecisionAgent
    |> where([mapping], mapping.simulation_run_record_id == ^run_record_id)
    |> group_by([mapping], mapping.agent_id)
    |> select([mapping], {mapping.agent_id, count(mapping.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp model_counts_by_type(run_record_id) do
    RunDecision
    |> where(
      [decision],
      decision.simulation_run_record_id == ^run_record_id and decision.source == "model"
    )
    |> group_by([decision], decision.agent_type)
    |> select([decision], {decision.agent_type, count(decision.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp next_sequence(run_record_id) do
    RunDecision
    |> where([decision], decision.simulation_run_record_id == ^run_record_id)
    |> select([decision], max(decision.sequence))
    |> Repo.one()
    |> Kernel.||(0)
    |> Kernel.+(1)
  end

  defp fallback_contract(group, reason) do
    %{
      "action_id" => group.hybrid["candidates"] |> List.wrap() |> Enum.sort() |> List.first(),
      "parameters" => %{},
      "reason_codes" => [reason],
      "short_rationale" =>
        "Applied the deterministic safe action because model cognition was unavailable.",
      "memory_updates" => %{},
      "uncertainty" => 1.0
    }
  end

  defp decision_key(record, round, signature),
    do:
      ContentHash.digest(%{
        "pack_hash" => record.pack_hash,
        "round" => round,
        "signature" => signature
      })

  defp relationship_degrees(relationships) do
    Enum.reduce(relationships, %{}, fn relationship, counts ->
      counts
      |> Map.update(relationship["source"], 1, &(&1 + 1))
      |> Map.update(relationship["target"], 1, &(&1 + 1))
    end)
  end

  defp degree_class(0), do: "isolated"
  defp degree_class(1), do: "single"
  defp degree_class(value) when value <= 5, do: "connected"
  defp degree_class(_value), do: "highly_connected"

  defp bucket_map(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(12)
    |> Map.new(fn {key, value} -> {to_string(key), bucket_value(value)} end)
  end

  defp bucket_map(_value), do: %{}
  defp bucket_value(value) when is_number(value) and value < 0.34, do: "low"
  defp bucket_value(value) when is_number(value) and value < 0.67, do: "medium"
  defp bucket_value(value) when is_number(value), do: "high"
  defp bucket_value(value) when is_boolean(value) or is_nil(value), do: value
  defp bucket_value(value) when is_binary(value), do: String.slice(value, 0, 40)

  defp bucket_value(value) when is_list(value),
    do: value |> Enum.take(4) |> Enum.map(&bucket_value/1)

  defp bucket_value(value) when is_map(value), do: bucket_map(value)
  defp bucket_value(_value), do: "other"

  defp representative_importance(agent) do
    value =
      get_in(agent, ["attributes", "importance"]) ||
        get_in(agent, ["attributes", "influence"]) ||
        get_in(agent, ["state", "importance"])

    clamp(number(value, 0.5))
  end

  defp provider_metadata(response) do
    %{
      "selected_provider" => response["provider"],
      "selected_model" => response["model"],
      "route" => response["route"] || %{}
    }
  end

  defp provider_timeout(record) do
    remaining = max(record.budget_plan.hard_runtime_seconds - elapsed_seconds(record), 1)
    min(remaining * 1_000, 120_000)
  end

  defp elapsed_seconds(%{started_at: nil}), do: 0

  defp elapsed_seconds(record) do
    max(DateTime.diff(DateTime.utc_now(), record.started_at, :second), 0)
  end

  defp usage_value(nil, _field), do: 0
  defp usage_value(reservation, field), do: Map.get(reservation, field) || 0

  defp fallback_reason(:invalid), do: "invalid_model_output"
  defp fallback_reason(:provider_error), do: "provider_failure"
  defp fallback_reason(:provider_exception), do: "provider_failure"
  defp fallback_reason(:timeout), do: "provider_timeout"
  defp fallback_reason(:route_unavailable), do: "model_route_unavailable"
  defp fallback_reason(:budget_fallback), do: "budget_exhausted"
  defp fallback_reason(:budget_error), do: "budget_unavailable"
  defp fallback_reason(_status), do: "deterministic_fallback"

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, decision}, {:ok, decisions} -> {:cont, {:ok, [decision | decisions]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, decisions} -> {:ok, Enum.reverse(decisions)}
      error -> error
    end
  end

  defp transaction_result({:ok, decision}), do: {:ok, decision}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp bounded_json?(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= 4_096
      _error -> false
    end
  end

  defp bounded_memory?(memory), do: map_size(memory) <= 16 and bounded_json?(memory)

  defp valid_reason_code?(code),
    do: is_binary(code) and String.match?(code, ~r/^[a-z][a-z0-9_]{0,63}$/)

  defp number(value, _default) when is_integer(value), do: value / 1
  defp number(value, _default) when is_float(value), do: value
  defp number(_value, default), do: default

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(_value, default), do: default

  defp clamp(value), do: value |> max(0.0) |> min(1.0)
  defp rounded(value), do: Float.round(value / 1, 6)

  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
