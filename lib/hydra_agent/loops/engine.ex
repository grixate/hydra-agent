defmodule HydraAgent.Loops.Engine do
  @moduledoc """
  Executes one governed loop tick.
  """

  alias HydraAgent.{AgentChat, Loops, Repo, Runtime, Safety, Usage}
  alias HydraAgent.Loops.Loop

  @decision_actions ~w(no_work dispatch_runs verify_runs request_attention pause_loop)
  @auto_start_levels ~w(execute_with_review execute_with_approval fully_automatic)

  def tick(%Loop{} = loop, opts \\ []) do
    now = now()
    owner = Keyword.get(opts, :lease_owner, lease_owner())
    started_at = System.monotonic_time(:millisecond)

    with {:ok, leased_loop} <- Loops.acquire_lease(loop, owner, now, lease_ttl_ms(loop)),
         :ok <- check_budget(leased_loop),
         {:ok, tick_run} <- create_tick_run(leased_loop, now),
         {:ok, running_run} <- Runtime.start_run(tick_run),
         {:ok, _event} <-
           record_event(leased_loop, running_run, "loop.tick.started", "Loop tick started"),
         {:ok, decision} <- decide(leased_loop, running_run, opts),
         :ok <- check_runtime_guardrail(leased_loop, started_at),
         {:ok, result} <- apply_decision(leased_loop, running_run, decision, opts),
         {:ok, released_loop} <- finish_loop(leased_loop, result, now) do
      {:ok, Map.put(result, :loop, released_loop)}
    else
      {:error, %{"reason" => "lease_conflict"} = error} ->
        {:error, error}

      {:error, error} ->
        fail_tick(loop, error, now)
    end
  end

  defp decide(loop, run, opts) do
    case Keyword.get(opts, :decision) do
      decision when is_map(decision) ->
        normalize_decision(decision)

      _nil ->
        ask_supervisor(loop, run)
    end
  end

  defp ask_supervisor(%Loop{supervisor_agent: nil}, _run) do
    {:error, %{"reason" => "loop_supervisor_agent_required"}}
  end

  defp ask_supervisor(loop, run) do
    prompt = decision_prompt(loop, run)

    with {:ok, conversation} <-
           AgentChat.start_conversation(loop.supervisor_agent, %{
             title: "Loop decision: #{loop.name}",
             channel: "loop",
             metadata: %{"loop_id" => loop.id, "run_id" => run.id}
           }),
         {:ok, response} <-
           AgentChat.respond(conversation, prompt,
             source: "loop",
             usage_category: "loop",
             run_id: run.id
           ),
         {:ok, decoded} <- decode_json(response.assistant_turn.content) do
      normalize_decision(decoded)
    end
  end

  defp apply_decision(loop, run, decision, opts) do
    with :ok <- check_child_run_guardrail(loop, decision),
         {:ok, verification} <- verify_decision(loop, run, decision, opts),
         :ok <- ensure_verification_passed(verification) do
      case decision["action"] do
        "no_work" ->
          complete_tick(loop, run, decision, verification, "no_work", [])

        "dispatch_runs" ->
          with {:ok, child_runs} <- dispatch_child_runs(loop, run, decision) do
            complete_tick(loop, run, decision, verification, "success", child_runs)
          end

        "verify_runs" ->
          complete_tick(loop, run, decision, verification, "success", [])

        "request_attention" ->
          block_tick(loop, run, decision, verification, "approval_required", "awaiting_approval")

        "pause_loop" ->
          block_tick(loop, run, decision, verification, "success", "paused")
      end
    end
  end

  defp complete_tick(loop, run, decision, verification, stop_reason, child_runs) do
    state = next_state(loop, decision)

    if no_progress_exhausted?(loop, state, decision) do
      block_tick(loop, run, decision, verification, "no_progress", "blocked")
    else
      result = %{
        "stop_reason" => stop_reason,
        "decision" => decision,
        "verification" => verification,
        "child_run_ids" => Enum.map(child_runs, & &1.id)
      }

      {:ok, completed_run} =
        Runtime.complete_run(run, %{
          "result" => result,
          "runtime_state" => Map.merge(run.runtime_state || %{}, %{"loop" => state}),
          "metadata" => loop_run_metadata(run, loop, decision, verification, stop_reason)
        })

      record_event(loop, completed_run, "loop.tick.completed", "Loop tick completed", result)

      {:ok,
       %{
         run: completed_run,
         decision: decision,
         verification: verification,
         state: state,
         child_runs: child_runs,
         status: loop.status,
         stop_reason: stop_reason,
         last_error: %{}
       }}
    end
  end

  defp block_tick(loop, run, decision, verification, stop_reason, run_status) do
    state = next_state(loop, decision)

    run_attrs = %{
      "result" => %{
        "stop_reason" => stop_reason,
        "decision" => decision,
        "verification" => verification
      },
      "runtime_state" => Map.merge(run.runtime_state || %{}, %{"loop" => state}),
      "metadata" => loop_run_metadata(run, loop, decision, verification, stop_reason)
    }

    {:ok, updated_run} =
      case run_status do
        "awaiting_approval" -> Runtime.transition_run(run, "awaiting_approval", run_attrs)
        "paused" -> Runtime.pause_run(run, run_attrs)
        "blocked" -> Runtime.transition_run(run, "blocked", run_attrs)
      end

    record_event(loop, updated_run, "loop.tick.blocked", "Loop tick blocked", %{
      "stop_reason" => stop_reason,
      "decision" => decision,
      "verification" => verification
    })

    {:ok,
     %{
       run: updated_run,
       decision: decision,
       verification: verification,
       state: state,
       child_runs: [],
       status: if(run_status == "paused", do: "paused", else: "blocked"),
       stop_reason: stop_reason,
       last_error: %{"reason" => stop_reason, "summary" => decision["summary"]}
     }}
  end

  defp dispatch_child_runs(loop, parent_run, decision) do
    decision
    |> Map.get("delegated_runs", [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {child, index}, {:ok, acc} ->
      attrs =
        child
        |> stringify_keys()
        |> Map.merge(%{
          "workspace_id" => loop.workspace_id,
          "mission_id" => loop.mission_id || parent_run.mission_id,
          "loop_id" => loop.id,
          "parent_run_id" => parent_run.id,
          "lineage_type" => "delegated",
          "lineage_reason" => "loop_dispatch",
          "title" => child["title"] || child[:title] || "Loop child run #{index + 1}",
          "goal" => child["goal"] || child[:goal] || child["title"] || child[:title],
          "supervisor_agent_id" =>
            child["supervisor_agent_id"] || child[:supervisor_agent_id] ||
              loop.supervisor_agent_id,
          "status" => "planned",
          "autonomy_level" => child["autonomy_level"] || loop.autonomy_level,
          "budget" => child["budget"] || loop.budget || %{},
          "metadata" =>
            Map.merge(child["metadata"] || child[:metadata] || %{}, %{
              "kind" => "loop_delegated_run",
              "loop_id" => loop.id,
              "loop_tick_run_id" => parent_run.id
            })
        })

      case Runtime.create_run(attrs) do
        {:ok, child_run} ->
          maybe_start_child_run(loop, child_run)
          {:cont, {:ok, [child_run | acc]}}

        {:error, error} ->
          {:halt, {:error, normalize_error(error)}}
      end
    end)
    |> case do
      {:ok, runs} -> {:ok, Enum.reverse(runs)}
      error -> error
    end
  end

  defp maybe_start_child_run(loop, run) do
    if loop.autonomy_level in @auto_start_levels and not approval_requested?(loop) do
      HydraAgent.Agent.Supervisor.start_run_worker(run.id)
    end
  end

  defp verify_decision(loop, run, decision, opts) do
    cond do
      verifier_decision = Keyword.get(opts, :verifier_decision) ->
        normalize_verification(verifier_decision)

      is_nil(loop.verifier_agent_id) ->
        {:ok, %{"passed" => true, "summary" => "No verifier configured."}}

      decision["action"] in ["request_attention", "pause_loop", "no_work"] ->
        {:ok,
         %{"passed" => true, "summary" => "Verification not required for #{decision["action"]}."}}

      true ->
        ask_verifier(loop, run, decision)
    end
  end

  defp ask_verifier(loop, run, decision) do
    loop = Repo.preload(loop, [:verifier_agent])

    with {:ok, conversation} <-
           AgentChat.start_conversation(loop.verifier_agent, %{
             title: "Loop verification: #{loop.name}",
             channel: "loop_verifier",
             metadata: %{"loop_id" => loop.id, "run_id" => run.id}
           }),
         {:ok, response} <-
           AgentChat.respond(conversation, verifier_prompt(loop, run, decision),
             source: "loop_verifier",
             usage_category: "loop",
             run_id: run.id
           ),
         {:ok, decoded} <- decode_json(response.assistant_turn.content),
         {:ok, verification} <- normalize_verification(decoded) do
      record_event(loop, run, "loop.verify.passed", "Loop verification passed", verification)
      {:ok, verification}
    else
      {:error, error} ->
        normalized = normalize_error(error)
        record_event(loop, run, "loop.verify.failed", "Loop verification failed", normalized)
        {:error, Map.put(normalized, "reason", normalized["reason"] || "verifier_failed")}
    end
  end

  defp ensure_verification_passed(%{"passed" => true}), do: :ok
  defp ensure_verification_passed(_verification), do: {:error, %{"reason" => "verifier_failed"}}

  defp finish_loop(loop, result, now) do
    attrs = %{
      "status" => result.status,
      "state" => result.state,
      "last_tick_at" => now,
      "last_error" => result.last_error,
      "metadata" =>
        Map.merge(loop.metadata || %{}, %{
          "last_run_id" => result.run.id,
          "last_stop_reason" => result.stop_reason,
          "last_decision_action" => result.decision["action"]
        }),
      "next_tick_at" =>
        if(result.status == "active", do: Loops.next_tick_at(loop, now), else: nil)
    }

    Loops.release_lease(loop, attrs)
  end

  defp fail_tick(loop, error, now) do
    normalized = normalize_error(error)

    loop =
      try do
        Loops.get_loop!(loop.id)
      rescue
        _error -> loop
      end

    Loops.release_lease(loop, %{
      "status" => "blocked",
      "last_tick_at" => now,
      "last_error" => normalized,
      "metadata" =>
        Map.merge(loop.metadata || %{}, %{
          "last_stop_reason" => normalized["reason"] || "error"
        }),
      "next_tick_at" => nil
    })

    Safety.record_event(%{
      workspace_id: loop.workspace_id,
      agent_id: loop.supervisor_agent_id,
      category: "runtime",
      severity: "warning",
      action: "loop_tick_failed",
      summary: "Loop tick failed",
      metadata: %{"loop_id" => loop.id, "error" => normalized}
    })

    {:error, normalized}
  end

  defp create_tick_run(loop, now) do
    Runtime.create_run(%{
      workspace_id: loop.workspace_id,
      mission_id: loop.mission_id,
      loop_id: loop.id,
      supervisor_agent_id: loop.supervisor_agent_id,
      title: "Loop tick: #{loop.name}",
      goal: loop.purpose,
      status: "planned",
      autonomy_level: loop.autonomy_level,
      budget: loop.budget || %{},
      plan: %{
        "loop_id" => loop.id,
        "loop_body" => loop.body,
        "guardrails" => loop.guardrails,
        "trigger" => loop.trigger
      },
      metadata: %{
        "kind" => "loop_tick",
        "loop_id" => loop.id,
        "loop_slug" => loop.slug,
        "scheduled_for" => DateTime.to_iso8601(now)
      }
    })
  end

  defp normalize_decision(decision) do
    decision = stringify_keys(decision || %{})
    action = decision["action"]

    cond do
      action not in @decision_actions ->
        {:error, %{"reason" => "invalid_loop_decision_action", "action" => action}}

      blank?(decision["summary"]) ->
        {:error, %{"reason" => "invalid_loop_decision", "message" => "summary is required"}}

      not is_map(decision["state_patch"] || %{}) ->
        {:error, %{"reason" => "invalid_loop_decision", "message" => "state_patch must be a map"}}

      not is_list(decision["delegated_runs"] || []) ->
        {:error,
         %{"reason" => "invalid_loop_decision", "message" => "delegated_runs must be a list"}}

      true ->
        {:ok,
         Map.merge(
           %{
             "progress_fingerprint" => "",
             "state_patch" => %{},
             "delegated_runs" => []
           },
           decision
         )}
    end
  end

  defp normalize_verification(verification) when is_map(verification) do
    verification = stringify_keys(verification)

    {:ok,
     %{
       "passed" => verification["passed"] == true,
       "summary" => verification["summary"] || "",
       "metadata" => verification["metadata"] || %{}
     }}
  end

  defp normalize_verification(_verification),
    do: {:error, %{"reason" => "invalid_loop_verification"}}

  defp next_state(loop, decision) do
    fingerprint = to_string(decision["progress_fingerprint"] || "")
    current_state = loop.state || %{}
    prior_fingerprint = current_state["last_progress_fingerprint"]

    no_progress_count =
      if fingerprint != "" and fingerprint == prior_fingerprint do
        (current_state["consecutive_no_progress"] || 0) + 1
      else
        0
      end

    current_state
    |> Map.merge(decision["state_patch"] || %{})
    |> Map.put("last_progress_fingerprint", fingerprint)
    |> Map.put("consecutive_no_progress", no_progress_count)
    |> Map.put("last_decision_summary", decision["summary"])
    |> Map.put("last_decision_action", decision["action"])
    |> Map.put("last_decision_at", DateTime.to_iso8601(now()))
  end

  defp no_progress_exhausted?(loop, state, decision) do
    decision["action"] != "no_work" and
      positive?(guardrail(loop, "max_consecutive_no_progress")) and
      (state["consecutive_no_progress"] || 0) >= guardrail(loop, "max_consecutive_no_progress")
  end

  defp check_child_run_guardrail(loop, %{"delegated_runs" => runs}) do
    max = guardrail(loop, "max_child_runs_per_tick")

    if positive?(max) and length(runs || []) > max do
      {:error,
       %{
         "reason" => "max_iterations",
         "message" => "delegated run count exceeds max_child_runs_per_tick",
         "max_child_runs_per_tick" => max
       }}
    else
      :ok
    end
  end

  defp check_runtime_guardrail(loop, started_at) do
    max_seconds = guardrail(loop, "max_runtime_seconds")
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    if positive?(max_seconds) and elapsed_ms > max_seconds * 1_000 do
      {:error, %{"reason" => "max_runtime_seconds", "elapsed_ms" => elapsed_ms}}
    else
      :ok
    end
  end

  defp check_budget(loop) do
    summary = Usage.summarize(loop.workspace_id, loop_id: loop.id)
    token_limit = budget_or_guardrail(loop, "token_limit")
    cost_limit = budget_or_guardrail(loop, "cost_limit")

    cond do
      positive?(token_limit) and summary["total_tokens"] >= token_limit ->
        {:error,
         %{
           "reason" => "budget_exceeded",
           "dimension" => "tokens",
           "token_limit" => token_limit,
           "total_tokens" => summary["total_tokens"]
         }}

      cost_limit_exceeded?(summary["estimated_cost"], cost_limit) ->
        {:error,
         %{
           "reason" => "budget_exceeded",
           "dimension" => "cost",
           "cost_limit" => to_string(cost_limit),
           "estimated_cost" => to_string(summary["estimated_cost"])
         }}

      true ->
        :ok
    end
  end

  defp cost_limit_exceeded?(_cost, nil), do: false
  defp cost_limit_exceeded?(_cost, 0), do: false

  defp cost_limit_exceeded?(cost, limit) do
    Decimal.compare(decimal(cost || 0), decimal(limit)) in [:gt, :eq]
  end

  defp record_event(loop, run, event_type, summary, payload \\ %{}) do
    Runtime.record_run_event(%{
      workspace_id: loop.workspace_id,
      run_id: run.id,
      agent_id: loop.supervisor_agent_id,
      event_type: event_type,
      summary: summary,
      payload: Map.merge(%{"loop_id" => loop.id}, payload)
    })
  end

  defp loop_run_metadata(run, loop, decision, verification, stop_reason) do
    Map.merge(run.metadata || %{}, %{
      "loop_id" => loop.id,
      "loop_slug" => loop.slug,
      "loop_decision" => decision,
      "loop_verification" => verification,
      "loop_stop_reason" => stop_reason
    })
  end

  defp decision_prompt(loop, run) do
    """
    You are executing a Hydra governed loop. Return only strict JSON.

    Allowed actions: no_work, dispatch_runs, verify_runs, request_attention, pause_loop.

    Required JSON shape:
    {
      "action": "no_work | dispatch_runs | verify_runs | request_attention | pause_loop",
      "summary": "short operator-facing summary",
      "progress_fingerprint": "stable string describing meaningful progress, or empty when none",
      "state_patch": {},
      "delegated_runs": [
        {"title": "Run title", "goal": "Run goal", "supervisor_agent_id": null, "metadata": {}}
      ]
    }

    Loop:
    #{Jason.encode!(loop_summary(loop))}

    Current tick run:
    #{Jason.encode!(%{id: run.id, title: run.title, goal: run.goal})}
    """
  end

  defp verifier_prompt(loop, run, decision) do
    """
    Verify this Hydra loop decision. Return only strict JSON:
    {"passed": true, "summary": "why", "metadata": {}}

    Loop:
    #{Jason.encode!(loop_summary(loop))}

    Run:
    #{Jason.encode!(%{id: run.id, title: run.title})}

    Decision:
    #{Jason.encode!(decision)}
    """
  end

  defp loop_summary(loop) do
    %{
      id: loop.id,
      name: loop.name,
      purpose: loop.purpose,
      trigger: loop.trigger,
      body: loop.body,
      autonomy_level: loop.autonomy_level,
      guardrails: loop.guardrails,
      state: loop.state
    }
  end

  defp decode_json(content) when is_binary(content) do
    content
    |> String.trim()
    |> strip_fence()
    |> Jason.decode()
    |> case do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, error} ->
        {:error, %{"reason" => "invalid_loop_decision_json", "error" => inspect(error)}}
    end
  end

  defp decode_json(_content), do: {:error, %{"reason" => "invalid_loop_decision_json"}}

  defp strip_fence("```json\n" <> rest), do: rest |> String.trim_trailing("```") |> String.trim()
  defp strip_fence("```\n" <> rest), do: rest |> String.trim_trailing("```") |> String.trim()
  defp strip_fence(content), do: content

  defp normalize_error(%Ecto.Changeset{} = changeset) do
    %{"reason" => "changeset_error", "errors" => changeset_errors(changeset)}
  end

  defp normalize_error(error) when is_map(error), do: stringify_keys(error)
  defp normalize_error(error), do: %{"reason" => inspect(error)}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp guardrail(loop, key) do
    loop.guardrails
    |> Map.get(key)
    |> normalize_integer()
  end

  defp budget_or_guardrail(loop, key) do
    Map.get(loop.guardrails || %{}, key) || Map.get(loop.budget || %{}, key)
  end

  defp positive?(value) when is_integer(value), do: value > 0
  defp positive?(_value), do: false

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _error -> 0
    end
  end

  defp normalize_integer(_value), do: 0

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> decimal
      _error -> Decimal.new(0)
    end
  end

  defp approval_requested?(loop) do
    get_in(loop.body || %{}, ["requires_approval"]) == true
  end

  defp lease_ttl_ms(loop), do: max(guardrail(loop, "max_runtime_seconds") * 1_000, 60_000)
  defp lease_owner, do: "loop-#{System.unique_integer([:positive])}"

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
