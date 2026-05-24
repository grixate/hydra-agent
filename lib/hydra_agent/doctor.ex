defmodule HydraAgent.Doctor do
  @moduledoc """
  Runtime self-diagnostics for operators and CI smoke checks.

  Doctor checks are intentionally shallow and fast. They answer whether the
  runtime is wired correctly enough to accept work, not whether every external
  provider will successfully complete a long task.
  """

  alias HydraAgent.{AgentPack, Providers, Repo, Runtime}
  alias HydraAgent.Tools.Registry

  @processes [
    HydraAgent.ProcessRegistry,
    HydraAgent.PubSub,
    HydraAgent.TaskSupervisor,
    HydraAgent.Agent.Supervisor,
    HydraAgent.Runtime.RecoveryWorker,
    HydraAgent.Automations.Worker
  ]

  def run(opts \\ []) do
    checks =
      []
      |> add_check(database_check())
      |> add_check(tool_registry_check())
      |> add_check(agent_pack_check(Keyword.get(opts, :agent_pack_glob, "agent_packs/*.json")))
      |> add_check(process_check())
      |> maybe_add_provider_checks(Keyword.get(opts, :workspace_id))

    %{
      "status" => status(checks),
      "checks" => checks,
      "summary" => summarize(checks)
    }
  end

  def status(checks) do
    cond do
      Enum.any?(checks, &(&1["status"] == "error")) -> "error"
      Enum.any?(checks, &(&1["status"] == "warning")) -> "warning"
      true -> "ok"
    end
  end

  def summarize(checks) do
    checks
    |> Enum.group_by(& &1["status"])
    |> Map.new(fn {status, status_checks} -> {status, length(status_checks)} end)
    |> Map.merge(%{"total" => length(checks)}, fn _key, left, _right -> left end)
  end

  defp add_check(checks, check), do: checks ++ [check]

  defp database_check do
    case Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} ->
        check("database", "ok", "Repository connection is available")

      {:error, error} ->
        check("database", "error", "Repository connection failed", %{
          "error" => inspect(error)
        })
    end
  rescue
    error ->
      check("database", "error", "Repository check crashed", %{
        "error" => Exception.message(error)
      })
  end

  defp tool_registry_check do
    tools = Registry.all()
    names = Enum.map(tools, & &1.name)
    duplicate_names = duplicate_values(names)

    cond do
      tools == [] ->
        check("tool_registry", "error", "No tools are registered")

      duplicate_names != [] ->
        check("tool_registry", "error", "Duplicate tool names found", %{
          "duplicates" => duplicate_names
        })

      true ->
        check("tool_registry", "ok", "Registered tools are unique", %{
          "count" => length(tools),
          "parallel_safe" => Enum.count(tools, & &1.parallel_safe)
        })
    end
  end

  defp agent_pack_check(glob) do
    paths = Path.wildcard(glob)

    results =
      Enum.map(paths, fn path ->
        case AgentPack.load_json(path) do
          {:ok, pack} -> %{"path" => path, "status" => "ok", "slug" => pack["slug"]}
          {:error, error} -> %{"path" => path, "status" => "error", "error" => error}
        end
      end)

    failed = Enum.filter(results, &(&1["status"] == "error"))

    cond do
      paths == [] ->
        check("agent_packs", "warning", "No starter agent packs found", %{"glob" => glob})

      failed != [] ->
        check("agent_packs", "error", "Some starter agent packs are invalid", %{
          "count" => length(paths),
          "failed" => failed
        })

      true ->
        check("agent_packs", "ok", "Starter agent packs are valid", %{
          "count" => length(paths),
          "packs" => results
        })
    end
  end

  defp process_check do
    results =
      Enum.map(@processes, fn name ->
        %{
          "name" => inspect(name),
          "status" => if(Process.whereis(name), do: "ok", else: "warning")
        }
      end)

    missing = Enum.filter(results, &(&1["status"] != "ok"))

    if missing == [] do
      check("otp_processes", "ok", "Expected runtime processes are registered", %{
        "processes" => results
      })
    else
      check("otp_processes", "warning", "Some runtime processes are not currently registered", %{
        "processes" => results
      })
    end
  end

  defp maybe_add_provider_checks(checks, nil), do: checks

  defp maybe_add_provider_checks(checks, workspace_id) do
    providers =
      workspace_id
      |> Runtime.list_providers()
      |> Enum.map(&provider_health_check/1)

    checks ++ providers
  rescue
    error ->
      checks ++
        [
          check("providers", "error", "Provider checks failed", %{
            "workspace_id" => workspace_id,
            "error" => Exception.message(error)
          })
        ]
  end

  defp provider_health_check(provider) do
    case Providers.health(provider) do
      :ok ->
        check("provider:#{provider.name}", "ok", "Provider health check passed", %{
          "id" => provider.id,
          "kind" => provider.kind,
          "model" => provider.model
        })

      {:error, error} ->
        check("provider:#{provider.name}", "warning", "Provider health check failed", %{
          "id" => provider.id,
          "kind" => provider.kind,
          "model" => provider.model,
          "error" => error
        })
    end
  end

  defp check(name, status, summary, metadata \\ %{}) do
    %{
      "name" => name,
      "status" => status,
      "summary" => summary,
      "metadata" => metadata
    }
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end
end
