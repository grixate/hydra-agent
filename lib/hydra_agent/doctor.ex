defmodule HydraAgent.Doctor do
  @moduledoc """
  Runtime self-diagnostics for operators and CI smoke checks.

  Doctor checks are intentionally shallow and fast. They answer whether the
  runtime is wired correctly enough to accept work, not whether every external
  provider will successfully complete a long task.
  """

  import Ecto.Query

  alias HydraAgent.{AgentPack, Automations, Connectors, MCP, Providers, Repo, Runtime, Secrets}
  alias HydraAgent.Connectors.Account
  alias HydraAgent.Rooms.ChannelBinding
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
      |> add_check(browser_worker_check())
      |> maybe_add_provider_checks(Keyword.get(opts, :workspace_id))
      |> maybe_add_workspace_readiness_checks(Keyword.get(opts, :workspace_id))

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

  defp browser_worker_check do
    case Application.get_env(:hydra_agent, :browser_worker_url) do
      nil ->
        check(
          "browser_worker",
          "ok",
          "Browser worker is not configured; browser tools record durable intents"
        )

      "" ->
        check("browser_worker", "warning", "Browser worker URL is empty")

      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            check("browser_worker", "ok", "Browser worker URL is configured", %{"url" => url})

          _uri ->
            check("browser_worker", "warning", "Browser worker URL is invalid", %{"url" => url})
        end
    end
  end

  defp maybe_add_workspace_readiness_checks(checks, nil), do: checks

  defp maybe_add_workspace_readiness_checks(checks, workspace_id) do
    checks ++
      [
        telegram_readiness_check(workspace_id),
        connector_readiness_check(workspace_id),
        automation_readiness_check(workspace_id),
        mcp_readiness_check(workspace_id)
      ]
  rescue
    error ->
      checks ++
        [
          check("workspace_readiness", "error", "Workspace readiness checks failed", %{
            "workspace_id" => workspace_id,
            "error" => Exception.message(error)
          })
        ]
  end

  defp telegram_readiness_check(workspace_id) do
    bindings =
      ChannelBinding
      |> where([binding], binding.workspace_id == ^normalize_id(workspace_id))
      |> where([binding], binding.provider == "telegram" and binding.status == "active")
      |> Repo.all()

    findings =
      Enum.flat_map(bindings, fn binding ->
        []
        |> maybe_add_finding(
          blank?(binding.token_env),
          binding_finding(binding, "token_env_missing")
        )
        |> maybe_add_finding(
          env_missing?(binding.token_env),
          binding_finding(binding, "token_env_not_configured", %{"env" => binding.token_env})
        )
        |> maybe_add_finding(
          blank?(binding.secret_env),
          binding_finding(binding, "secret_env_missing")
        )
        |> maybe_add_finding(
          env_missing?(binding.secret_env),
          binding_finding(binding, "secret_env_not_configured", %{"env" => binding.secret_env})
        )
        |> maybe_add_finding(
          pending_telegram_capture?(binding),
          binding_finding(binding, "chat_id_capture_pending")
        )
        |> maybe_add_finding(
          map_size(binding.last_error || %{}) > 0,
          binding_finding(binding, "last_delivery_error", %{"last_error" => binding.last_error})
        )
      end)

    cond do
      bindings == [] ->
        check("telegram", "warning", "No active Telegram room bindings configured", %{
          "workspace_id" => workspace_id
        })

      findings == [] ->
        check("telegram", "ok", "Telegram room bindings are configured", %{
          "workspace_id" => workspace_id,
          "bindings" => length(bindings)
        })

      true ->
        check("telegram", "warning", "Telegram room bindings need attention", %{
          "workspace_id" => workspace_id,
          "bindings" => length(bindings),
          "findings" => findings
        })
    end
  end

  defp connector_readiness_check(workspace_id) do
    accounts = Connectors.list_accounts(workspace_id)
    findings = Enum.flat_map(accounts, &connector_findings/1)

    cond do
      accounts == [] ->
        check("connectors", "warning", "No connector accounts configured", %{
          "workspace_id" => workspace_id
        })

      findings == [] ->
        check("connectors", "ok", "Connector accounts are configured", %{
          "workspace_id" => workspace_id,
          "accounts" => length(accounts)
        })

      true ->
        check("connectors", "warning", "Connector accounts need attention", %{
          "workspace_id" => workspace_id,
          "accounts" => length(accounts),
          "findings" => findings
        })
    end
  end

  defp automation_readiness_check(workspace_id) do
    automations = Automations.list_automations(workspace_id)
    active = Enum.filter(automations, &(&1.status == "active"))
    connector_accounts = Connectors.list_accounts(workspace_id)
    findings = Enum.flat_map(active, &automation_findings(&1, connector_accounts))

    cond do
      active == [] ->
        check("automations", "warning", "No active automations configured", %{
          "workspace_id" => workspace_id
        })

      findings == [] ->
        check("automations", "ok", "Active automations are schedulable", %{
          "workspace_id" => workspace_id,
          "active" => length(active)
        })

      true ->
        check("automations", "warning", "Active automations need attention", %{
          "workspace_id" => workspace_id,
          "active" => length(active),
          "findings" => findings
        })
    end
  end

  defp mcp_readiness_check(workspace_id) do
    servers = MCP.list_servers(workspace_id)
    active = Enum.filter(servers, &(&1.status == "active"))

    findings =
      Enum.flat_map(active, fn server ->
        []
        |> maybe_add_finding(
          server.health_status in ["unknown", "unhealthy"],
          %{
            "id" => server.id,
            "slug" => server.slug,
            "reason" => "mcp_health_not_healthy",
            "health_status" => server.health_status,
            "last_error" => server.last_error
          }
        )
        |> maybe_add_finding(env_refs_missing?(server.env_refs || []), %{
          "id" => server.id,
          "slug" => server.slug,
          "reason" => "mcp_env_refs_not_configured",
          "env_refs" => missing_env_refs(server.env_refs || [])
        })
      end)

    cond do
      active == [] ->
        check("mcp", "ok", "No active MCP servers configured", %{"workspace_id" => workspace_id})

      findings == [] ->
        check("mcp", "ok", "Active MCP servers look ready", %{
          "workspace_id" => workspace_id,
          "active" => length(active)
        })

      true ->
        check("mcp", "warning", "Active MCP servers need attention", %{
          "workspace_id" => workspace_id,
          "active" => length(active),
          "findings" => findings
        })
    end
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

  defp connector_findings(%Account{} = account) do
    requirements = Enum.find(Connectors.provider_specs(), &(&1.provider == account.provider))

    config_fields =
      get_in(requirements || %{}, [:setup, :config_fields])
      |> List.wrap()
      |> Enum.filter(&required_connector_config_field?(account.provider, &1))

    []
    |> maybe_add_finding(
      account.status != "active",
      connector_finding(account, "connector_not_active")
    )
    |> maybe_add_finding(
      connector_credential_missing?(account, requirements),
      connector_finding(account, "credential_env_missing")
    )
    |> maybe_add_finding(
      env_missing?(account.credential_env),
      connector_finding(account, "credential_env_not_configured", %{
        "env" => account.credential_env
      })
    )
    |> maybe_add_finding(
      missing_config_fields(account, config_fields) != [],
      connector_finding(account, "required_config_missing", %{
        "fields" => missing_config_fields(account, config_fields)
      })
    )
    |> maybe_add_finding(
      map_size(account.last_error || %{}) > 0,
      connector_finding(account, "last_health_error", %{"last_error" => account.last_error})
    )
  end

  defp automation_findings(automation, connector_accounts) do
    readiness = Automations.readiness(automation, connector_accounts)
    missing = missing_required_connector_providers(readiness)

    []
    |> maybe_add_finding(is_nil(automation.next_run_at), %{
      "id" => automation.id,
      "slug" => automation.slug,
      "reason" => "next_run_missing"
    })
    |> maybe_add_finding(missing != [], %{
      "id" => automation.id,
      "slug" => automation.slug,
      "reason" => "required_connectors_missing",
      "providers" => missing
    })
    |> maybe_add_finding(readiness["blockers"] != [], %{
      "id" => automation.id,
      "slug" => automation.slug,
      "reason" => "connector_readiness_blocked",
      "readiness" => readiness
    })
    |> maybe_add_finding(readiness["warnings"] != [], %{
      "id" => automation.id,
      "slug" => automation.slug,
      "reason" => "connector_readiness_pending",
      "readiness" => readiness
    })
    |> maybe_add_finding(map_size(automation.last_error || %{}) > 0, %{
      "id" => automation.id,
      "slug" => automation.slug,
      "reason" => "last_automation_error",
      "last_error" => automation.last_error
    })
  end

  defp missing_required_connector_providers(readiness) do
    readiness
    |> Map.get("blockers", [])
    |> Enum.filter(&(&1["reason"] == "connector_missing"))
    |> Enum.map(& &1["provider"])
  end

  defp binding_finding(binding, reason, extra \\ %{}) do
    Map.merge(%{"id" => binding.id, "slug" => binding.slug, "reason" => reason}, extra)
  end

  defp connector_finding(account, reason, extra \\ %{}) do
    Map.merge(
      %{
        "id" => account.id,
        "slug" => account.slug,
        "provider" => account.provider,
        "reason" => reason
      },
      extra
    )
  end

  defp maybe_add_finding(findings, true, finding), do: findings ++ [finding]
  defp maybe_add_finding(findings, _condition, _finding), do: findings

  defp connector_credential_missing?(account, requirements) do
    not is_nil(requirements && requirements.required_env) and blank?(account.credential_env)
  end

  defp required_connector_config_field?("linkedin", "author_urn"), do: true
  defp required_connector_config_field?(_provider, _field), do: false

  defp missing_config_fields(account, fields) do
    Enum.filter(fields, &blank?(get_in(account.config || %{}, [&1])))
  end

  defp pending_telegram_capture?(binding) do
    String.starts_with?(to_string(binding.external_chat_id || ""), "pending:") and
      get_in(binding.config || %{}, ["capture_chat_id"]) == true
  end

  defp env_refs_missing?(refs), do: missing_env_refs(refs) != []

  defp missing_env_refs(refs) do
    refs
    |> List.wrap()
    |> Enum.filter(&env_missing?/1)
  end

  defp env_missing?(nil), do: false
  defp env_missing?(""), do: false

  defp env_missing?(env) when is_binary(env) do
    match?({:error, _error}, Secrets.fetch_env(env))
  end

  defp env_missing?(_env), do: false

  defp blank?(value), do: is_nil(value) or value == ""

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp normalize_id(id), do: id
end
