defmodule HydraAgent.Runtime.Planner do
  @moduledoc """
  Provider-backed planning for durable runs.

  The planner asks the run supervisor agent for a strict JSON step plan and
  persists accepted steps through `HydraAgent.Runtime.Runner`.
  """

  alias HydraAgent.{Budgets, Providers, Runtime, Safety, Usage}
  alias HydraAgent.Runtime.{AgentProfile, Run, Runner}
  alias HydraAgent.Tools.Registry

  def generate_plan(%Run{} = run, opts \\ []) do
    run = Runtime.get_run!(run.id)

    with %AgentProfile{} = agent <- run.supervisor_agent,
         :ok <-
           Budgets.check_available(run.workspace_id, agent_id: agent.id, category: "planning"),
         {:ok, provider_response} <- Providers.chat(agent, build_request(run, agent, opts)),
         {:ok, steps} <- parse_plan(get_in(provider_response, ["message", "content"]) || ""),
         :ok <- validate_steps(steps),
         {:ok, planned_steps} <- Runner.plan_steps(run, steps) do
      Usage.record_provider_response(
        %{workspace_id: run.workspace_id, agent_id: agent.id, run_id: run.id},
        provider_response,
        "planning"
      )

      {:ok,
       %{
         run: Runtime.get_run!(run.id),
         steps: planned_steps,
         provider_response: provider_response
       }}
    else
      nil ->
        {:error, %{"reason" => "missing_supervisor_agent"}}

      {:error, error} ->
        record_runtime_error(run, error)
        Usage.record_error(%{workspace_id: run.workspace_id, run_id: run.id}, error, "planning")
        {:error, error}
    end
  end

  def build_request(%Run{} = run, %AgentProfile{} = agent, opts \\ []) do
    available_tools =
      Registry.all()
      |> Enum.map(fn spec ->
        %{
          "name" => spec.name,
          "side_effect_class" => spec.side_effect_class,
          "description" => spec.description
        }
      end)

    content = """
    Create a concise executable plan for this run.

    Run title: #{run.title}
    Run goal: #{run.goal}
    Run autonomy level: #{run.autonomy_level}

    Available tools:
    #{Jason.encode!(available_tools)}

    Return only JSON in this exact shape:
    {
      "steps": [
        {
          "title": "Short imperative step title",
          "assigned_agent_id": #{agent.id || "null"},
          "tool_name": "noop",
          "side_effect_class": "read_only",
          "input": {}
        }
      ]
    }
    """

    %{
      "messages" => [
        %{
          "role" => "system",
          "content" =>
            agent.system_prompt ||
              "You are a careful planner. Produce small, auditable, least-privilege steps."
        },
        %{"role" => "user", "content" => content}
      ],
      "temperature" => Keyword.get(opts, :temperature, 0.2),
      "max_tokens" => Keyword.get(opts, :max_tokens, 1200)
    }
  end

  def parse_plan(content) when is_binary(content) do
    content
    |> extract_json()
    |> Jason.decode()
    |> case do
      {:ok, %{"steps" => steps}} when is_list(steps) ->
        {:ok, Enum.map(steps, &normalize_step/1)}

      {:ok, _decoded} ->
        {:error, %{"reason" => "plan_missing_steps"}}

      {:error, error} ->
        {:error, %{"reason" => "invalid_plan_json", "error" => Exception.message(error)}}
    end
  end

  def parse_plan(_content), do: {:error, %{"reason" => "plan_content_must_be_string"}}

  defp validate_steps(steps) do
    unknown_tools =
      steps
      |> Enum.map(& &1["tool_name"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Kernel.--([""])
      |> Kernel.--(Registry.names())

    cond do
      steps == [] ->
        {:error, %{"reason" => "plan_has_no_steps"}}

      unknown_tools != [] ->
        {:error, %{"reason" => "plan_references_unknown_tools", "tools" => unknown_tools}}

      true ->
        :ok
    end
  end

  defp normalize_step(step) when is_map(step) do
    step
    |> stringify_keys()
    |> Map.put_new("side_effect_class", "read_only")
    |> Map.put_new("input", %{})
  end

  defp normalize_step(_step), do: %{}

  defp extract_json(content) do
    trimmed = String.trim(content)

    cond do
      String.starts_with?(trimmed, "```") ->
        trimmed
        |> String.replace_prefix("```json", "")
        |> String.replace_prefix("```", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      true ->
        trimmed
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp record_runtime_error(run, %{"reason" => "budget_exceeded"} = error) do
    Safety.record_event(%{
      workspace_id: run.workspace_id,
      agent_id: run.supervisor_agent_id,
      run_id: run.id,
      category: "runtime",
      severity: "warning",
      action: "planning_budget_exceeded",
      summary: "Planning blocked by budget",
      metadata: error
    })
  end

  defp record_runtime_error(_run, _error), do: :ok
end
