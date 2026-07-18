defmodule HydraAgent.Simulations.BudgetGovernor do
  @moduledoc """
  Atomic execution-budget reservations for Simulation Build, Run, and Report work.

  The Governor reserves the maximum request envelope before work begins. It
  never treats the simulated Resource Ledger as execution budget, and it never
  invents a monetary guarantee when a route has no captured price.
  """

  import Ecto.Query

  alias Decimal, as: D
  alias HydraAgent.Repo

  alias HydraAgent.Simulations.{
    BudgetPlan,
    BudgetReservation,
    PriceRegistry,
    SimulationRunRecord
  }

  @stages ~w(research build simulation report)
  @kinds ~w(provider_call retrieval)
  @active_statuses ~w(reserved completed)

  def reserve(%BudgetPlan{} = plan, stage, request, opts \\ []) do
    request = stringify_map(request)
    stage = to_string(stage)
    kind = request["kind"] || "provider_call"
    fallback? = Keyword.get(opts, :on_exhaustion) == :fallback

    with true <- stage in @stages,
         true <- kind in @kinds,
         {:ok, envelope} <- request_envelope(plan, stage, kind, request, opts) do
      Repo.transaction(fn ->
        locked_plan =
          BudgetPlan
          |> where([candidate], candidate.id == ^plan.id)
          |> lock("FOR UPDATE")
          |> Repo.one!()

        existing =
          BudgetReservation
          |> where(
            [reservation],
            reservation.budget_plan_id == ^locked_plan.id and
              reservation.idempotency_key == ^envelope.idempotency_key
          )
          |> Repo.one()

        if existing do
          existing_result(existing, fallback?)
        else
          reservations =
            BudgetReservation
            |> where([reservation], reservation.budget_plan_id == ^locked_plan.id)
            |> lock("FOR UPDATE")
            |> Repo.all()

          case reservation_error(locked_plan, reservations, envelope) do
            nil ->
              insert_reservation!(locked_plan, envelope, "reserved", nil)

            reason ->
              fallback = fallback_for(reason)
              chosen_fallback = if(fallback?, do: fallback)

              rejected =
                insert_reservation!(
                  locked_plan,
                  envelope,
                  "rejected",
                  chosen_fallback,
                  reason,
                  %{"recommended_fallback" => fallback}
                )

              if fallback?,
                do: {:fallback, rejected},
                else: {:rejected, error(reason, locked_plan, reservations, envelope), rejected}
          end
        end
      end)
      |> unwrap_transaction()
    else
      false -> {:error, %{"reason" => "invalid_budget_request"}}
      {:error, reason} -> {:error, %{"reason" => to_string(reason)}}
    end
  end

  def complete(%BudgetReservation{} = reservation, usage) when is_map(usage) do
    usage = stringify_map(usage)

    Repo.transaction(fn ->
      current =
        BudgetReservation
        |> where([candidate], candidate.id == ^reservation.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      plan = Repo.get!(BudgetPlan, current.budget_plan_id)

      cond do
        current.status == "completed" ->
          current

        current.status != "reserved" ->
          Repo.rollback(%{"reason" => "reservation_not_active"})

        true ->
          with {:ok, input, output} <- actual_usage(current.kind, usage),
               {:ok, actual_cost} <- actual_cost(plan, current, usage, input, output) do
            cond do
              input > current.max_input_tokens or output > current.max_output_tokens ->
                Repo.rollback(%{"reason" => "provider_usage_exceeded_reservation"})

              not is_nil(current.reserved_cost) and not is_nil(actual_cost) and
                  D.compare(actual_cost, current.reserved_cost) == :gt ->
                Repo.rollback(%{"reason" => "provider_cost_exceeded_reservation"})

              not is_nil(plan.hard_cost_cap) and is_nil(actual_cost) ->
                Repo.rollback(%{"reason" => "actual_cost_required"})

              true ->
                current
                |> BudgetReservation.changeset(%{
                  status: "completed",
                  actual_input_tokens: input,
                  actual_output_tokens: output,
                  actual_cost: actual_cost,
                  usage_record_id: usage["usage_record_id"],
                  metadata: Map.merge(current.metadata || %{}, stringify_map(usage["metadata"])),
                  completed_at: DateTime.utc_now()
                })
                |> Repo.update!()
            end
          else
            {:error, reason} -> Repo.rollback(%{"reason" => reason})
          end
      end
    end)
    |> unwrap_transaction()
  end

  def release(%BudgetReservation{} = reservation, fallback \\ "deterministic_rule") do
    Repo.transaction(fn ->
      current =
        BudgetReservation
        |> where([candidate], candidate.id == ^reservation.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if current.status == "reserved" do
        current
        |> BudgetReservation.changeset(%{
          status: "released",
          actual_input_tokens: 0,
          actual_output_tokens: 0,
          actual_cost: if(current.pricing_known, do: D.new(0), else: nil),
          fallback: fallback,
          completed_at: DateTime.utc_now()
        })
        |> Repo.update!()
      else
        current
      end
    end)
    |> unwrap_transaction()
  end

  @doc "Closes a dispatched provider request conservatively when reliable usage is unavailable."
  def fail(%BudgetReservation{} = reservation, failure, fallback \\ "deterministic_rule") do
    Repo.transaction(fn ->
      current =
        BudgetReservation
        |> where([candidate], candidate.id == ^reservation.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if current.status == "reserved" do
        current
        |> BudgetReservation.changeset(%{
          status: "completed",
          actual_input_tokens: current.max_input_tokens,
          actual_output_tokens: current.max_output_tokens,
          actual_cost: current.reserved_cost,
          fallback: fallback,
          metadata:
            Map.merge(current.metadata || %{}, %{
              "provider_failure" => safe_failure(failure),
              "usage_accounting" => "reserved_envelope"
            }),
          completed_at: DateTime.utc_now()
        })
        |> Repo.update!()
      else
        current
      end
    end)
    |> unwrap_transaction()
  end

  def summary(%BudgetPlan{} = plan, opts \\ []) do
    run_record_id = Keyword.get(opts, :simulation_run_record_id)

    reservations =
      BudgetReservation
      |> where([reservation], reservation.budget_plan_id == ^plan.id)
      |> maybe_filter_run(run_record_id)
      |> Repo.all()

    totals = effective_totals(reservations)

    %{
      "pricing_status" => plan.pricing_status,
      "currency" => plan.currency,
      "used_cost" => decimal_string(totals.cost),
      "remaining_cost" => remaining_decimal(plan.hard_cost_cap, totals.cost),
      "input_tokens" => totals.input,
      "remaining_input_tokens" => max(plan.hard_input_token_cap - totals.input, 0),
      "output_tokens" => totals.output,
      "remaining_output_tokens" => max(plan.hard_output_token_cap - totals.output, 0),
      "model_calls" => totals.model_calls,
      "remaining_model_calls" => max(plan.hard_model_call_cap - totals.model_calls, 0),
      "retrieval_requests" => totals.retrievals,
      "remaining_retrieval_requests" =>
        max(plan.hard_retrieval_request_cap - totals.retrievals, 0),
      "active_reservations" => totals.active,
      "fallbacks" => totals.fallbacks,
      "by_stage" => stage_summary(reservations)
    }
  end

  defp request_envelope(plan, stage, kind, request, opts) do
    run_record_id = Keyword.get(opts, :simulation_run_record_id)
    route = route_for(plan, stage)

    with {:ok, input} <- nonnegative_integer(request["max_input_tokens"]),
         {:ok, output} <- nonnegative_integer(request["max_output_tokens"]),
         {:ok, elapsed} <- nonnegative_integer(Keyword.get(opts, :elapsed_runtime_seconds, 0)),
         :ok <- validate_run(plan, run_record_id),
         :ok <- validate_route(kind, route, request) do
      price = price_for(plan, stage, kind)
      reserved_cost = PriceRegistry.estimate_max(price, input, output)

      {:ok,
       %{
         stage: stage,
         kind: kind,
         provider: request["provider"] || route["provider"],
         model: request["model"] || route["model"],
         input: input,
         output: output,
         reserved_cost: reserved_cost,
         pricing_known: not is_nil(reserved_cost),
         idempotency_key: request["idempotency_key"],
         run_record_id: run_record_id,
         elapsed_runtime_seconds: elapsed,
         metadata: stringify_map(request["metadata"])
       }}
    end
    |> case do
      {:ok, %{idempotency_key: key} = envelope}
      when is_binary(key) and byte_size(key) == 64 ->
        if Regex.match?(~r/^[a-f0-9]{64}$/, key),
          do: {:ok, envelope},
          else: {:error, :invalid_idempotency_key}

      {:ok, _envelope} ->
        {:error, :invalid_idempotency_key}

      error ->
        error
    end
  end

  defp validate_run(_plan, nil), do: :ok

  defp validate_run(plan, run_record_id) do
    case Repo.get(SimulationRunRecord, run_record_id) do
      %{workspace_id: workspace_id, budget_plan_id: budget_plan_id}
      when workspace_id == plan.workspace_id and budget_plan_id == plan.id ->
        :ok

      _other ->
        {:error, :run_budget_scope_mismatch}
    end
  end

  defp validate_route("retrieval", _route, _request), do: :ok

  defp validate_route("provider_call", %{"status" => "resolved"} = route, request) do
    provider = request["provider"] || route["provider"]
    model = request["model"] || route["model"]

    if provider == route["provider"] and model == route["model"],
      do: :ok,
      else: {:error, :route_mismatch}
  end

  defp validate_route("provider_call", %{"status" => "disabled"}, _request),
    do: {:error, :model_lane_disabled}

  defp validate_route("provider_call", _route, _request),
    do: {:error, :model_route_unavailable}

  defp reservation_error(plan, reservations, envelope) do
    totals = effective_totals(reservations)
    stage = stage_totals(reservations, envelope.stage)
    stage_cap = plan.stage_caps[envelope.stage] || %{}
    requested_calls = if envelope.kind == "provider_call", do: 1, else: 0
    requested_retrievals = if envelope.kind == "retrieval", do: 1, else: 0

    cond do
      envelope.elapsed_runtime_seconds >= plan.hard_runtime_seconds ->
        "runtime_cap_exhausted"

      totals.active >= plan.max_concurrency ->
        "concurrency_cap_exhausted"

      totals.model_calls + requested_calls > plan.hard_model_call_cap ->
        "model_call_cap_exhausted"

      totals.retrievals + requested_retrievals > plan.hard_retrieval_request_cap ->
        "retrieval_cap_exhausted"

      stage.calls + 1 > (stage_cap["calls"] || 0) ->
        "stage_call_cap_exhausted"

      totals.input + envelope.input > plan.hard_input_token_cap ->
        "input_token_cap_exhausted"

      totals.output + envelope.output > plan.hard_output_token_cap ->
        "output_token_cap_exhausted"

      stage.input + envelope.input > (stage_cap["input_tokens"] || 0) ->
        "stage_input_token_cap_exhausted"

      stage.output + envelope.output > (stage_cap["output_tokens"] || 0) ->
        "stage_output_token_cap_exhausted"

      not is_nil(plan.hard_cost_cap) and is_nil(envelope.reserved_cost) ->
        "price_unknown"

      exceeds_cost?(totals.cost, envelope.reserved_cost, plan.hard_cost_cap) ->
        "cost_cap_exhausted"

      exceeds_stage_cost?(stage.cost, envelope.reserved_cost, stage_cap["cost"]) ->
        "stage_cost_cap_exhausted"

      true ->
        nil
    end
  end

  defp insert_reservation!(
         plan,
         envelope,
         status,
         fallback,
         reason \\ nil,
         extra_metadata \\ %{}
       ) do
    metadata =
      envelope.metadata
      |> Map.put("runtime_seconds_at_reservation", envelope.elapsed_runtime_seconds)
      |> maybe_put("rejection_reason", reason)
      |> Map.merge(extra_metadata)

    %BudgetReservation{}
    |> BudgetReservation.changeset(%{
      workspace_id: plan.workspace_id,
      budget_plan_id: plan.id,
      simulation_run_record_id: envelope.run_record_id,
      kind: envelope.kind,
      stage: envelope.stage,
      status: status,
      provider: envelope.provider,
      model: envelope.model,
      max_input_tokens: envelope.input,
      max_output_tokens: envelope.output,
      reserved_cost: envelope.reserved_cost,
      pricing_known: envelope.pricing_known,
      idempotency_key: envelope.idempotency_key,
      fallback: fallback,
      metadata: metadata,
      completed_at: if(status == "rejected", do: DateTime.utc_now())
    })
    |> Repo.insert!()
  end

  defp existing_result(%{status: "rejected"} = reservation, true),
    do: {:fallback, reservation}

  defp existing_result(%{status: "rejected"} = reservation, false) do
    {:rejected,
     %{
       "reason" => reservation.metadata["rejection_reason"] || "budget_reservation_rejected"
     }, reservation}
  end

  defp existing_result(reservation, _fallback?), do: reservation

  defp effective_totals(reservations) do
    Enum.reduce(reservations, empty_totals(), fn reservation, totals ->
      if reservation.status in @active_statuses do
        %{
          input: totals.input + effective_input(reservation),
          output: totals.output + effective_output(reservation),
          cost: D.add(totals.cost, effective_cost(reservation)),
          model_calls:
            totals.model_calls + if(reservation.kind == "provider_call", do: 1, else: 0),
          retrievals: totals.retrievals + if(reservation.kind == "retrieval", do: 1, else: 0),
          active: totals.active + if(reservation.status == "reserved", do: 1, else: 0),
          fallbacks: totals.fallbacks + if(is_binary(reservation.fallback), do: 1, else: 0)
        }
      else
        %{
          totals
          | fallbacks: totals.fallbacks + if(is_binary(reservation.fallback), do: 1, else: 0)
        }
      end
    end)
  end

  defp stage_totals(reservations, stage) do
    selected = Enum.filter(reservations, &(&1.stage == stage and &1.status in @active_statuses))
    totals = effective_totals(selected)
    Map.put(totals, :calls, totals.model_calls + totals.retrievals)
  end

  defp empty_totals do
    %{input: 0, output: 0, cost: D.new(0), model_calls: 0, retrievals: 0, active: 0, fallbacks: 0}
  end

  defp stage_summary(reservations) do
    Map.new(@stages, fn stage ->
      totals = stage_totals(reservations, stage)

      {stage,
       %{
         "calls" => totals.calls,
         "input_tokens" => totals.input,
         "output_tokens" => totals.output,
         "cost" => decimal_string(totals.cost)
       }}
    end)
  end

  defp actual_usage("provider_call", usage) do
    with true <- Map.has_key?(usage, "input_tokens") and Map.has_key?(usage, "output_tokens"),
         {:ok, input} <- nonnegative_integer(usage["input_tokens"]),
         {:ok, output} <- nonnegative_integer(usage["output_tokens"]) do
      {:ok, input, output}
    else
      _other -> {:error, "invalid_provider_usage"}
    end
  end

  defp actual_usage("retrieval", usage) do
    with {:ok, input} <- optional_nonnegative_integer(usage["input_tokens"]),
         {:ok, output} <- optional_nonnegative_integer(usage["output_tokens"]) do
      {:ok, input, output}
    else
      _other -> {:error, "invalid_provider_usage"}
    end
  end

  defp actual_cost(_plan, _reservation, %{"actual_cost" => nil}, _input, _output),
    do: {:ok, nil}

  defp actual_cost(_plan, _reservation, %{"actual_cost" => value}, _input, _output)
       when not is_nil(value) do
    case D.cast(value) do
      {:ok, cost} ->
        if D.compare(cost, 0) == :lt,
          do: {:error, "invalid_provider_cost"},
          else: {:ok, cost}

      :error ->
        {:error, "invalid_provider_cost"}
    end
  end

  defp actual_cost(plan, reservation, _usage, input, output) do
    {:ok,
     plan
     |> price_for(reservation.stage, reservation.kind)
     |> PriceRegistry.estimate_max(input, output)}
  end

  defp effective_input(%{status: "completed", actual_input_tokens: value}), do: value || 0
  defp effective_input(reservation), do: reservation.max_input_tokens
  defp effective_output(%{status: "completed", actual_output_tokens: value}), do: value || 0
  defp effective_output(reservation), do: reservation.max_output_tokens

  defp effective_cost(%{status: "completed", actual_cost: value}), do: value || D.new(0)
  defp effective_cost(reservation), do: reservation.reserved_cost || D.new(0)

  defp route_for(plan, "research"), do: plan.model_route_snapshot["build"] || %{}
  defp route_for(plan, stage), do: plan.model_route_snapshot[stage] || %{}

  defp price_for(plan, _stage, "retrieval"),
    do: get_in(plan.price_registry_snapshot, ["entries", "retrieval"]) || %{}

  defp price_for(plan, "research", _kind),
    do: get_in(plan.price_registry_snapshot, ["entries", "build"]) || %{}

  defp price_for(plan, stage, _kind),
    do: get_in(plan.price_registry_snapshot, ["entries", stage]) || %{}

  defp exceeds_cost?(_used, _reserved, nil), do: false
  defp exceeds_cost?(_used, nil, _cap), do: true

  defp exceeds_cost?(used, reserved, cap),
    do: D.compare(D.add(used, reserved), cap) == :gt

  defp exceeds_stage_cost?(_used, _reserved, nil), do: false
  defp exceeds_stage_cost?(_used, nil, _cap), do: true

  defp exceeds_stage_cost?(used, reserved, cap),
    do: D.compare(D.add(used, reserved), decimal(cap)) == :gt

  defp fallback_for(reason)
       when reason in [
              "model_call_cap_exhausted",
              "retrieval_cap_exhausted",
              "input_token_cap_exhausted",
              "output_token_cap_exhausted",
              "stage_call_cap_exhausted",
              "stage_input_token_cap_exhausted",
              "stage_output_token_cap_exhausted",
              "cost_cap_exhausted",
              "stage_cost_cap_exhausted",
              "runtime_cap_exhausted",
              "concurrency_cap_exhausted"
            ],
       do: "deterministic_rule"

  defp fallback_for("price_unknown"), do: "cheaper_or_local_model"
  defp fallback_for(_reason), do: "stop_model_lane"

  defp error(reason, plan, reservations, envelope) do
    totals = effective_totals(reservations)

    %{
      "reason" => reason,
      "budget_plan_id" => plan.id,
      "stage" => envelope.stage,
      "hard_cost_cap" => decimal_string(plan.hard_cost_cap),
      "reserved_cost" => decimal_string(totals.cost),
      "hard_model_call_cap" => plan.hard_model_call_cap,
      "model_calls" => totals.model_calls,
      "hard_input_token_cap" => plan.hard_input_token_cap,
      "input_tokens" => totals.input,
      "hard_output_token_cap" => plan.hard_output_token_cap,
      "output_tokens" => totals.output
    }
  end

  defp maybe_filter_run(query, nil), do: query

  defp maybe_filter_run(query, run_record_id),
    do: where(query, [reservation], reservation.simulation_run_record_id == ^run_record_id)

  defp unwrap_transaction({:ok, {:fallback, reservation}}), do: {:fallback, reservation}
  defp unwrap_transaction({:ok, {:rejected, error, _reservation}}), do: {:error, error}
  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp remaining_decimal(nil, _used), do: nil

  defp remaining_decimal(cap, used) do
    remaining = D.sub(cap, used)
    decimal_string(if(D.compare(remaining, 0) == :lt, do: D.new(0), else: remaining))
  end

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, :invalid_nonnegative_integer}
    end
  end

  defp nonnegative_integer(_value), do: {:error, :invalid_nonnegative_integer}

  defp optional_nonnegative_integer(nil), do: {:ok, 0}
  defp optional_nonnegative_integer(value), do: nonnegative_integer(value)

  defp decimal(%D{} = value), do: value
  defp decimal(value) when is_integer(value), do: D.new(value)
  defp decimal(value) when is_float(value), do: D.from_float(value)
  defp decimal(value) when is_binary(value), do: D.new(value)

  defp decimal_string(nil), do: nil
  defp decimal_string(%D{} = value), do: D.to_string(value, :normal)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_failure(failure) when is_map(failure) do
    %{
      "reason" =>
        failure["reason"] || failure[:reason] || failure["code"] || failure[:code] ||
          "provider_failure"
    }
  end

  defp safe_failure(failure) when is_atom(failure), do: %{"reason" => Atom.to_string(failure)}
  defp safe_failure(_failure), do: %{"reason" => "provider_failure"}

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_map(_value), do: %{}
end
