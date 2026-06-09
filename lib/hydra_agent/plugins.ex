defmodule HydraAgent.Plugins do
  @moduledoc """
  Durable plugin installation and capability registry.

  Plugins are workspace-scoped declarations. The core records their manifest,
  approvals, capability surface, and lifecycle events; runtime execution still
  goes through existing policy-gated tools, MCP, connector actions, or trusted
  in-release callback modules.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HydraAgent.Skills
  alias HydraAgent.Skills.Skill
  alias HydraAgent.Plugins.{Capability, Configuration, Event, Installation}
  alias HydraAgent.Repo
  alias HydraAgent.Runtime.Autonomy
  alias HydraAgent.Secrets
  alias HydraAgent.Tools.{Bundles, Registry}

  @manifest_version 1
  @capability_fields %{
    "tools" => "tool",
    "tool_bundles" => "tool_bundle",
    "agent_packs" => "agent_pack",
    "skills" => "skill",
    "mcp_servers" => "mcp_server",
    "connectors" => "connector",
    "room_channels" => "room_channel",
    "cli_commands" => "cli_command",
    "client_surfaces" => "client_surface",
    "migrations" => "migration"
  }
  @legacy_capability_fields %{"web_routes" => "client_surface"}
  @trusted_execution_types ~w(trusted_module migration)
  @external_execution_types ~w(mcp webhook project_skill)
  @package_types ~w(runtime_plugin client_app hybrid)
  @api_scopes ~w(
    workspaces:read workspaces:write
    agents:read agents:write
    rooms:read rooms:write
    runs:read runs:write
    tools:read tools:execute
    plugins:read plugins:manage
    providers:read providers:write
    connectors:read connectors:write
    skills:read skills:write
    memory:read memory:write
    knowledge:read knowledge:write
    audit:read
    admin:read admin:write
  )

  def manifest_version, do: @manifest_version

  def manifest_schema do
    %{
      "plugin_version" => @manifest_version,
      "required_fields" =>
        ~w(plugin_version slug name version trust_level permissions capabilities),
      "slug_format" => "^[a-z0-9][a-z0-9-]*$",
      "trust_levels" => Installation.trust_levels(),
      "source_types" => Installation.source_types(),
      "installation_statuses" => Installation.statuses(),
      "capability_kinds" => Capability.kinds(),
      "capability_statuses" => Capability.statuses(),
      "capability_fields" => @capability_fields,
      "legacy_capability_fields" => @legacy_capability_fields,
      "side_effect_classes" => Autonomy.side_effect_classes(),
      "tool_execution_types" => @external_execution_types ++ @trusted_execution_types,
      "trusted_execution_types" => @trusted_execution_types,
      "package_types" => @package_types,
      "api_scopes" => @api_scopes,
      "permissions" => %{
        "side_effect_classes" => ["read_only"],
        "requires_approval" => true,
        "env_refs" => [],
        "api_scopes" => []
      },
      "client_surface" => %{
        "kind" => "external_url",
        "surface" => "workspace",
        "entrypoint" => %{"type" => "external_url", "url_env" => "MY_PLUGIN_UI_URL"},
        "required_scopes" => ["workspaces:read"]
      },
      "config_schema" => %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      "source_security" => %{
        "git_source_ref" => "full 40-character commit SHA",
        "git_allowlist" => git_allowlist(%{}),
        "secret_storage" => "manifests store environment variable references, not raw secrets"
      }
    }
  end

  def list_installations(workspace_id, opts \\ []) do
    Installation
    |> where([plugin], plugin.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:status, opt(opts, :status))
    |> order_by([plugin], asc: plugin.slug)
    |> preload([:capabilities, :configuration])
    |> Repo.all()
  end

  def get_installation!(id) do
    Installation
    |> Repo.get!(normalize_id(id))
    |> Repo.preload([:capabilities, :configuration])
  end

  def get_installation_for_workspace!(workspace_id, id) do
    Installation
    |> where(
      [plugin],
      plugin.workspace_id == ^normalize_id(workspace_id) and plugin.id == ^normalize_id(id)
    )
    |> preload([:capabilities, :configuration])
    |> Repo.one!()
  end

  def get_configuration(%Installation{} = plugin) do
    plugin = Repo.preload(plugin, [:configuration], force: true)

    plugin.configuration ||
      %Configuration{
        workspace_id: plugin.workspace_id,
        plugin_installation_id: plugin.id,
        config: %{},
        metadata: %{}
      }
  end

  def update_configuration(%Installation{} = plugin, attrs \\ %{}) do
    attrs = stringify_keys(attrs || %{})
    config = stringify_keys(attrs["config"] || %{})

    with :ok <- validate_runtime_config(plugin, config) do
      existing = get_configuration(plugin)

      config_attrs = %{
        "workspace_id" => plugin.workspace_id,
        "plugin_installation_id" => plugin.id,
        "config" => config,
        "configured_by" => attrs["configured_by"] || attrs["approved_by"] || attrs["actor"],
        "configured_at" => now(),
        "metadata" => %{"schema_digest" => digest(Jason.encode!(plugin_config_schema(plugin)))}
      }

      Multi.new()
      |> Multi.insert_or_update(:configuration, Configuration.changeset(existing, config_attrs))
      |> Multi.insert(:event, fn %{configuration: configuration} ->
        Event.changeset(%Event{}, %{
          "workspace_id" => plugin.workspace_id,
          "plugin_installation_id" => plugin.id,
          "event_type" => "plugin.configured",
          "actor" => configuration.configured_by || "operator",
          "summary" => "Plugin configuration updated",
          "payload" => %{"configured_keys" => Map.keys(config) |> Enum.sort()}
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{configuration: configuration}} -> {:ok, configuration}
        {:error, _operation, error, _changes} -> {:error, error}
      end
    end
  end

  def list_capabilities(workspace_id, opts \\ []) do
    Capability
    |> where([capability], capability.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:kind, opt(opts, :kind))
    |> maybe_filter(:status, opt(opts, :status))
    |> order_by([capability], asc: capability.kind, asc: capability.name)
    |> Repo.all()
  end

  def client_contract(workspace_id) do
    workspace_id = normalize_id(workspace_id)
    plugins = list_installations(workspace_id)
    capabilities = list_capabilities(workspace_id)

    %{
      "workspace_id" => workspace_id,
      "manifest_schema" => manifest_schema(),
      "plugins" => Enum.map(plugins, &client_plugin_summary/1),
      "capabilities" => Enum.map(capabilities, &client_capability_summary/1),
      "client_surfaces" => enabled_client_surface_specs(workspace_id)
    }
  end

  def enabled_capabilities(nil, _kind), do: []

  def enabled_capabilities(workspace_id, kind) do
    Capability
    |> join(:inner, [capability], plugin in assoc(capability, :plugin_installation))
    |> where(
      [capability, plugin],
      capability.workspace_id == ^normalize_id(workspace_id) and capability.kind == ^kind and
        capability.status == "enabled" and plugin.status == "enabled"
    )
    |> order_by([capability, _plugin], asc: capability.name)
    |> Repo.all()
  end

  def enabled_tool_specs(workspace_id) do
    workspace_id
    |> enabled_capabilities("tool")
    |> Enum.map(&tool_spec_from_capability/1)
  end

  def enabled_tool_bundle_specs(workspace_id) do
    workspace_id
    |> enabled_capabilities("tool_bundle")
    |> Enum.map(&bundle_spec_from_capability/1)
  end

  def enabled_agent_packs(workspace_id) do
    workspace_id
    |> enabled_capabilities("agent_pack")
    |> Enum.map(&capability_payload/1)
  end

  def enabled_skill_specs(workspace_id) do
    workspace_id
    |> enabled_capabilities("skill")
    |> Enum.map(&capability_payload/1)
  end

  def enabled_mcp_server_templates(workspace_id) do
    workspace_id
    |> enabled_capabilities("mcp_server")
    |> Enum.map(&capability_payload/1)
  end

  def enabled_connector_specs(workspace_id) do
    workspace_id
    |> enabled_capabilities("connector")
    |> Enum.map(&capability_payload/1)
  end

  def enabled_room_channel_specs(workspace_id) do
    workspace_id
    |> enabled_capabilities("room_channel")
    |> Enum.map(&capability_payload/1)
  end

  def enabled_cli_command_specs(workspace_id) do
    workspace_id
    |> enabled_capabilities("cli_command")
    |> Enum.map(&capability_payload/1)
  end

  def enabled_web_route_specs(workspace_id) do
    enabled_client_surface_specs(workspace_id)
  end

  def enabled_client_surface_specs(workspace_id) do
    (enabled_capabilities(workspace_id, "client_surface") ++
       enabled_capabilities(workspace_id, "web_route"))
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&capability_payload/1)
  end

  def doctor(%Installation{} = plugin) do
    plugin = Repo.preload(plugin, [:capabilities, :configuration], force: true)
    manifest = stringify_keys(plugin.manifest || %{})
    permissions = stringify_keys(plugin.permissions || %{})

    env_refs =
      ((plugin.env_refs || []) ++ capability_env_refs(plugin.capabilities || []))
      |> Enum.uniq()
      |> Enum.sort()

    findings =
      []
      |> doctor_status_findings(plugin)
      |> doctor_env_findings(env_refs)
      |> doctor_manifest_findings(plugin, manifest, permissions)
      |> doctor_config_findings(plugin)
      |> doctor_capability_findings(plugin, plugin.capabilities || [])
      |> doctor_dependency_findings(plugin, manifest["dependencies"] || [])

    %{
      "id" => plugin.id,
      "slug" => plugin.slug,
      "name" => plugin.name,
      "version" => plugin.version,
      "status" => plugin.status,
      "readiness" => readiness(findings, plugin.status),
      "trust_level" => plugin.trust_level,
      "package_type" => manifest["package_type"],
      "source_type" => plugin.source_type,
      "source_url" => plugin.source_url,
      "source_ref" => plugin.source_ref,
      "manifest_digest" => plugin.manifest_digest,
      "env_refs" => env_refs,
      "permissions" => permissions,
      "api_scopes" => permissions["api_scopes"] || [],
      "config_schema" => manifest["config_schema"] || %{},
      "config_status" => config_status(plugin),
      "compatibility" => manifest["compatibility"] || %{},
      "dependencies" => manifest["dependencies"] || [],
      "capability_count" => length(plugin.capabilities || []),
      "capability_counts" => capability_counts(plugin.capabilities || []),
      "warnings" => get_in(plugin.metadata || %{}, ["warnings"]) || [],
      "last_error" => plugin.last_error || %{},
      "findings" => Enum.reverse(findings)
    }
  end

  def scan_path(workspace_id, path, attrs \\ []) when is_binary(path) do
    attrs = attrs |> Enum.into(%{}) |> stringify_keys()
    source_path = Path.expand(path)
    manifest_path = manifest_path(source_path)

    with true <- File.exists?(manifest_path),
         {:ok, body} <- File.read(manifest_path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, manifest} <- validate_manifest(decoded),
         :ok <- validate_capability_conflicts(workspace_id, manifest, attrs),
         digest <- digest(body) do
      {:ok,
       %{
         "source_type" => "local_path",
         "source_path" => source_path,
         "manifest_path" => manifest_path,
         "manifest_digest" => digest,
         "manifest" => manifest,
         "capabilities" => capability_specs(manifest),
         "warnings" => scan_warnings(manifest)
       }}
    else
      false ->
        {:error, %{"reason" => "plugin_manifest_not_found", "path" => source_path}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, %{"reason" => "invalid_plugin_json", "error" => Exception.message(error)}}

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  def scan_git(workspace_id, source_url, source_ref, attrs \\ %{}) do
    attrs = stringify_keys(attrs || %{})

    with :ok <- validate_git_source(source_url, source_ref, attrs),
         {:ok, checkout_path} <- checkout_git_source(source_url, source_ref, attrs),
         {:ok, scan} <- scan_path(workspace_id, checkout_path, attrs) do
      {:ok,
       scan
       |> Map.put("source_type", "git")
       |> Map.put("source_url", source_url)
       |> Map.put("source_ref", source_ref)}
    end
  end

  def install_from_path(workspace_id, path, attrs \\ %{}) do
    attrs = stringify_keys(attrs || %{})

    with {:ok, scan} <- scan_path(workspace_id, path, attrs),
         :ok <- require_install_approval(attrs),
         {:ok, plugin} <- upsert_installation(workspace_id, scan, attrs) do
      {:ok, plugin}
    end
  end

  def install_from_git(workspace_id, source_url, source_ref, attrs \\ %{}) do
    attrs = stringify_keys(attrs || %{})

    with {:ok, scan} <- scan_git(workspace_id, source_url, source_ref, attrs),
         :ok <- require_install_approval(attrs),
         {:ok, plugin} <- upsert_installation(workspace_id, scan, attrs) do
      {:ok, plugin}
    end
  end

  def upgrade_from_path(%Installation{} = plugin, path, attrs \\ %{}) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("status", plugin.status)
      |> Map.put("source_url", plugin.source_url)
      |> Map.put("source_ref", plugin.source_ref)

    install_from_path(plugin.workspace_id, path, attrs)
  end

  def upgrade_from_git(%Installation{} = plugin, source_url, source_ref, attrs \\ %{}) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("status", plugin.status)

    install_from_git(plugin.workspace_id, source_url, source_ref, attrs)
  end

  def enable_installation(%Installation{} = plugin, attrs \\ %{}) do
    attrs = stringify_keys(attrs || %{})

    with :ok <- require_install_approval(attrs),
         :ok <- plugin_ready_for_enable(plugin),
         {:ok, plugin} <-
           update_installation_status(
             plugin,
             "enabled",
             attrs,
             "plugin.enabled",
             "Plugin enabled"
           ),
         {:ok, _assets} <- materialize_enabled_assets(plugin, attrs) do
      {:ok, plugin}
    end
  end

  def disable_installation(%Installation{} = plugin, attrs \\ %{}) do
    update_installation_status(
      plugin,
      "disabled",
      stringify_keys(attrs || %{}),
      "plugin.disabled",
      "Plugin disabled"
    )
  end

  def uninstall_installation(%Installation{} = plugin, attrs \\ %{}) do
    update_installation_status(
      plugin,
      "uninstalled",
      stringify_keys(attrs || %{}),
      "plugin.uninstalled",
      "Plugin uninstalled"
    )
  end

  def migration_plan(%Installation{} = plugin, attrs \\ %{}) do
    attrs = stringify_keys(attrs || %{})

    with :ok <- trusted_plugin(plugin),
         {:ok, migrations} <- migration_capabilities(plugin),
         {:ok, plans} <- run_migration_callbacks(plugin, migrations, attrs, :plan),
         {:ok, _event} <-
           record_event(
             plugin,
             "plugin.migrations.dry_run",
             attrs,
             "Plugin migrations dry-run",
             %{
               "migration_count" => length(migrations),
               "plans" => plans
             }
           ) do
      {:ok,
       %{"plugin_id" => plugin.id, "migration_count" => length(migrations), "plans" => plans}}
    end
  end

  def run_migrations(%Installation{} = plugin, attrs \\ %{}) do
    attrs = stringify_keys(attrs || %{})

    with :ok <- require_install_approval(attrs),
         :ok <- trusted_plugin(plugin),
         true <- attrs["dry_run_confirmed"] == true or attrs["dry_run_confirmed"] == "true",
         {:ok, migrations} <- migration_capabilities(plugin),
         {:ok, results} <- run_migration_callbacks(plugin, migrations, attrs, :run),
         {:ok, _event} <-
           record_event(
             plugin,
             "plugin.migrations.applied",
             attrs,
             "Plugin migrations applied",
             %{
               "migration_count" => length(migrations),
               "results" => results
             }
           ) do
      {:ok,
       %{"plugin_id" => plugin.id, "migration_count" => length(migrations), "results" => results}}
    else
      false -> {:error, %{"reason" => "plugin_migration_dry_run_confirmation_required"}}
      error -> error
    end
  end

  defp upsert_installation(workspace_id, scan, attrs) do
    manifest = scan["manifest"]
    now = now()

    install_attrs = %{
      "workspace_id" => workspace_id,
      "slug" => manifest["slug"],
      "name" => manifest["name"],
      "version" => manifest["version"],
      "description" => manifest["description"],
      "status" => attrs["status"] || "installed",
      "source_type" => scan["source_type"],
      "source_path" => scan["source_path"],
      "source_url" => scan["source_url"] || attrs["source_url"],
      "source_ref" => scan["source_ref"] || attrs["source_ref"],
      "trust_level" => manifest["trust_level"],
      "manifest" => manifest,
      "manifest_digest" => scan["manifest_digest"],
      "permissions" => manifest["permissions"],
      "env_refs" => manifest["permissions"]["env_refs"] || [],
      "approved_by" => attrs["approved_by"],
      "approved_at" => now,
      "metadata" => %{"warnings" => scan["warnings"]}
    }

    existing =
      Installation
      |> where(
        [plugin],
        plugin.workspace_id == ^normalize_id(workspace_id) and plugin.slug == ^manifest["slug"]
      )
      |> Repo.one()

    Multi.new()
    |> Multi.insert_or_update(
      :plugin,
      (existing || %Installation{}) |> Installation.changeset(install_attrs)
    )
    |> Multi.delete_all(:old_capabilities, fn %{plugin: plugin} ->
      from(capability in Capability, where: capability.plugin_installation_id == ^plugin.id)
    end)
    |> Multi.run(:capabilities, fn repo, %{plugin: plugin} ->
      scan["capabilities"]
      |> Enum.reduce_while({:ok, []}, fn capability_attrs, {:ok, capabilities} ->
        capability_attrs =
          capability_attrs
          |> Map.put("workspace_id", workspace_id)
          |> Map.put("plugin_installation_id", plugin.id)

        case repo.insert(Capability.changeset(%Capability{}, capability_attrs)) do
          {:ok, capability} -> {:cont, {:ok, capabilities ++ [capability]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    end)
    |> Multi.insert(:event, fn %{plugin: plugin} ->
      Event.changeset(%Event{}, %{
        "workspace_id" => workspace_id,
        "plugin_installation_id" => plugin.id,
        "event_type" => if(existing, do: "plugin.upgraded", else: "plugin.installed"),
        "actor" => attrs["approved_by"] || "operator",
        "summary" => if(existing, do: "Plugin upgraded", else: "Plugin installed"),
        "payload" => %{
          "slug" => manifest["slug"],
          "version" => manifest["version"],
          "manifest_digest" => scan["manifest_digest"],
          "capability_count" => length(scan["capabilities"])
        }
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{plugin: plugin}} -> {:ok, get_installation!(plugin.id)}
      {:error, _operation, error, _changes} -> {:error, error}
    end
  end

  defp update_installation_status(plugin, status, attrs, event_type, summary) do
    Multi.new()
    |> Multi.update(:plugin, Installation.changeset(plugin, %{"status" => status}))
    |> Multi.run(:capabilities, fn repo, %{plugin: plugin} ->
      {count, _rows} =
        repo.update_all(
          from(capability in Capability, where: capability.plugin_installation_id == ^plugin.id),
          set: [status: capability_status(status), updated_at: now()]
        )

      {:ok, count}
    end)
    |> Multi.insert(:event, fn %{plugin: plugin} ->
      Event.changeset(%Event{}, %{
        "workspace_id" => plugin.workspace_id,
        "plugin_installation_id" => plugin.id,
        "event_type" => event_type,
        "actor" => attrs["approved_by"] || attrs["actor"] || "operator",
        "summary" => summary,
        "payload" => %{"status" => status}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{plugin: plugin}} -> {:ok, get_installation!(plugin.id)}
      {:error, _operation, error, _changes} -> {:error, error}
    end
  end

  defp capability_status("enabled"), do: "enabled"
  defp capability_status(_status), do: "disabled"

  defp migration_capabilities(%Installation{} = plugin) do
    plugin = Repo.preload(plugin, [:capabilities])

    migrations =
      plugin.capabilities
      |> Enum.filter(&(&1.kind == "migration" and &1.status == "enabled"))
      |> Enum.sort_by(& &1.name)

    {:ok, migrations}
  end

  defp run_migration_callbacks(plugin, migrations, attrs, operation) do
    migrations
    |> Enum.reduce_while({:ok, []}, fn capability, {:ok, results} ->
      case run_migration_callback(plugin, capability, attrs, operation) do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp run_migration_callback(plugin, capability, attrs, operation) do
    spec = stringify_keys(capability.spec || %{})
    execution = stringify_keys(spec["execution"] || %{})

    with {:ok, module} <- trusted_module(execution["module"]),
         true <- function_exported?(module, operation, 1) do
      apply(module, operation, [
        %{
          "workspace_id" => plugin.workspace_id,
          "plugin_id" => plugin.id,
          "capability_id" => capability.id,
          "migration" => spec,
          "attrs" => attrs
        }
      ])
    else
      false ->
        {:error,
         %{
           "reason" => "plugin_migration_callback_missing",
           "migration" => capability.name,
           "operation" => to_string(operation)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp trusted_module(module_name) when is_binary(module_name) do
    module = module_name |> String.split(".", trim: true) |> Module.concat()

    case Code.ensure_loaded(module) do
      {:module, module} ->
        {:ok, module}

      {:error, reason} ->
        {:error,
         %{
           "reason" => "plugin_trusted_module_not_loaded",
           "module" => module_name,
           "detail" => inspect(reason)
         }}
    end
  rescue
    _error -> {:error, %{"reason" => "plugin_trusted_module_invalid", "module" => module_name}}
  end

  defp trusted_module(_module_name),
    do: {:error, %{"reason" => "plugin_trusted_module_required"}}

  defp trusted_plugin(%Installation{trust_level: "trusted"}), do: :ok

  defp trusted_plugin(%Installation{} = plugin) do
    {:error,
     %{
       "reason" => "plugin_trusted_tier_required",
       "plugin_id" => plugin.id,
       "trust_level" => plugin.trust_level
     }}
  end

  defp plugin_ready_for_enable(%Installation{} = plugin) do
    report = doctor(plugin)
    errors = Enum.filter(report["findings"], &(&1["severity"] == "error"))

    if errors == [] do
      :ok
    else
      {:error,
       %{
         "reason" => "plugin_not_ready_for_enable",
         "plugin_id" => plugin.id,
         "readiness" => report["readiness"],
         "findings" => errors
       }}
    end
  end

  defp record_event(%Installation{} = plugin, event_type, attrs, summary, payload) do
    %Event{}
    |> Event.changeset(%{
      "workspace_id" => plugin.workspace_id,
      "plugin_installation_id" => plugin.id,
      "event_type" => event_type,
      "actor" => attrs["approved_by"] || attrs["actor"] || "operator",
      "summary" => summary,
      "payload" => payload
    })
    |> Repo.insert()
  end

  defp materialize_enabled_assets(%Installation{} = plugin, attrs) do
    plugin = Repo.preload(plugin, [:capabilities])

    plugin.capabilities
    |> Enum.filter(&(&1.kind == "skill" and &1.status == "enabled"))
    |> Enum.reduce_while({:ok, []}, fn capability, {:ok, assets} ->
      case materialize_skill(plugin, capability, attrs) do
        {:ok, asset} -> {:cont, {:ok, assets ++ [asset]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp materialize_skill(%Installation{} = plugin, %Capability{} = capability, attrs) do
    spec = stringify_keys(capability.spec || %{})
    slug = spec["slug"] || capability.name

    existing =
      Skill
      |> where([skill], skill.workspace_id == ^plugin.workspace_id and skill.slug == ^slug)
      |> Repo.one()

    if existing do
      {:ok, existing}
    else
      plugin_allowed_tools =
        plugin.workspace_id
        |> enabled_tool_specs()
        |> Enum.map(& &1.name)

      Skills.create_skill(%{
        workspace_id: plugin.workspace_id,
        name: spec["name"] || spec["title"] || titleize(slug),
        slug: slug,
        description: spec["description"] || "Plugin-provided skill.",
        status: spec["status"] || "proposed",
        instructions:
          spec["instructions"] || spec["procedure"] || "Follow the plugin-provided instructions.",
        trigger_conditions: spec["trigger_conditions"] || %{"source" => "plugin"},
        required_tools: spec["required_tools"] || [],
        memory_scopes: spec["memory_scopes"] || ["workspace"],
        knowledge_scopes: spec["knowledge_scopes"] || ["workspace"],
        provenance: %{
          "kind" => "plugin_skill",
          "plugin_slug" => plugin.slug,
          "plugin_installation_id" => plugin.id,
          "plugin_capability_id" => capability.id,
          "plugin_allowed_tools" => plugin_allowed_tools,
          "enabled_by" => attrs["approved_by"] || attrs["actor"] || "operator",
          "enabled_at" => DateTime.to_iso8601(now())
        }
      })
    end
  end

  def validate_manifest(manifest) when is_map(manifest) do
    manifest = stringify_keys(manifest)

    []
    |> require_fields(
      manifest,
      ~w(plugin_version slug name version trust_level permissions capabilities)
    )
    |> validate_version(manifest)
    |> validate_slug(manifest)
    |> validate_package_type(manifest)
    |> validate_trust_level(manifest)
    |> validate_permissions(manifest)
    |> validate_config_schema(manifest)
    |> validate_compatibility(manifest)
    |> validate_dependencies(manifest)
    |> validate_capabilities(manifest)
    |> validate_secret_like_config(manifest)
    |> case do
      [] ->
        {:ok, normalize_manifest(manifest)}

      errors ->
        {:error, %{"reason" => "invalid_plugin_manifest", "errors" => Enum.reverse(errors)}}
    end
  end

  def validate_manifest(_manifest),
    do: {:error, %{"reason" => "invalid_plugin_manifest", "errors" => ["manifest must be a map"]}}

  defp require_fields(errors, manifest, fields) do
    missing = Enum.reject(fields, &Map.has_key?(manifest, &1))

    if missing == [] do
      errors
    else
      ["missing required fields: #{Enum.join(missing, ", ")}" | errors]
    end
  end

  defp validate_version(errors, %{"plugin_version" => @manifest_version}), do: errors

  defp validate_version(errors, _manifest),
    do: ["plugin_version must be #{@manifest_version}" | errors]

  defp validate_slug(errors, %{"slug" => slug}) when is_binary(slug) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, slug),
      do: errors,
      else: ["slug is invalid" | errors]
  end

  defp validate_slug(errors, _manifest), do: ["slug is invalid" | errors]

  defp validate_package_type(errors, manifest) do
    package_type = manifest["package_type"] || manifest["plugin_type"] || "runtime_plugin"

    if package_type in @package_types do
      errors
    else
      ["package_type must be one of #{Enum.join(@package_types, ", ")}" | errors]
    end
  end

  defp validate_trust_level(errors, %{"trust_level" => trust_level}) do
    if trust_level in Installation.trust_levels() do
      errors
    else
      ["trust_level must be one of #{Enum.join(Installation.trust_levels(), ", ")}" | errors]
    end
  end

  defp validate_permissions(errors, %{"permissions" => permissions}) when is_map(permissions) do
    permissions = stringify_keys(permissions)
    side_effect_classes = List.wrap(permissions["side_effect_classes"] || ["read_only"])
    requires_approval = Map.get(permissions, "requires_approval", true)
    env_refs = List.wrap(permissions["env_refs"] || [])
    api_scopes = List.wrap(permissions["api_scopes"] || [])

    errors =
      case side_effect_classes -- Autonomy.side_effect_classes() do
        [] ->
          errors

        unknown ->
          [
            "permissions contain unknown side_effect_classes: #{Enum.join(unknown, ", ")}"
            | errors
          ]
      end

    errors =
      if side_effect_classes -- ["read_only"] != [] and requires_approval == false do
        ["dangerous plugin permissions must require approval" | errors]
      else
        errors
      end

    case Enum.reject(env_refs, &valid_env_ref?/1) do
      [] ->
        errors

      invalid ->
        ["permissions contain invalid env_refs: #{Enum.join(invalid, ", ")}" | errors]
    end
    |> then(fn errors ->
      case Enum.reject(api_scopes, &valid_api_scope?/1) do
        [] ->
          errors

        invalid ->
          ["permissions contain invalid api_scopes: #{Enum.join(invalid, ", ")}" | errors]
      end
    end)
  end

  defp validate_permissions(errors, _manifest), do: ["permissions must be a map" | errors]

  defp validate_config_schema(errors, %{"config_schema" => schema}) when is_map(schema) do
    schema = stringify_keys(schema)

    cond do
      schema["type"] not in [nil, "object"] ->
        ["config_schema.type must be object" | errors]

      Map.has_key?(schema, "properties") and not is_map(schema["properties"]) ->
        ["config_schema.properties must be a map" | errors]

      Map.has_key?(schema, "required") and not is_list(schema["required"]) ->
        ["config_schema.required must be a list" | errors]

      true ->
        errors
    end
  end

  defp validate_config_schema(errors, %{"config_schema" => _schema}),
    do: ["config_schema must be a map" | errors]

  defp validate_config_schema(errors, _manifest), do: errors

  defp validate_compatibility(errors, %{"compatibility" => compatibility})
       when is_map(compatibility) do
    compatibility = stringify_keys(compatibility)

    constraint = compatibility["hydra_version"]

    cond do
      is_nil(constraint) ->
        errors

      not is_binary(constraint) ->
        ["compatibility.hydra_version must be a string" | errors]

      not version_constraint_satisfied?(hydra_version(), constraint) ->
        ["compatibility.hydra_version does not match runtime #{hydra_version()}" | errors]

      true ->
        errors
    end
  end

  defp validate_compatibility(errors, %{"compatibility" => _compatibility}),
    do: ["compatibility must be a map" | errors]

  defp validate_compatibility(errors, _manifest), do: errors

  defp validate_dependencies(errors, %{"dependencies" => dependencies})
       when is_list(dependencies) do
    dependencies
    |> Enum.with_index()
    |> Enum.reduce(errors, fn
      {dependency, index}, acc when is_map(dependency) ->
        dependency = stringify_keys(dependency)

        cond do
          not valid_dependency_slug?(dependency["plugin"]) ->
            ["dependencies.#{index}.plugin is invalid" | acc]

          Map.has_key?(dependency, "version") and not is_binary(dependency["version"]) ->
            ["dependencies.#{index}.version must be a string" | acc]

          true ->
            acc
        end

      {_dependency, index}, acc ->
        ["dependencies.#{index} must be a map" | acc]
    end)
  end

  defp validate_dependencies(errors, %{"dependencies" => _dependencies}),
    do: ["dependencies must be a list" | errors]

  defp validate_dependencies(errors, _manifest), do: errors

  defp validate_capabilities(errors, %{"capabilities" => capabilities})
       when is_map(capabilities) do
    capabilities = stringify_keys(capabilities)

    Enum.reduce(all_capability_fields(), errors, fn {field, kind}, acc ->
      capability_items = capabilities[field] || []

      cond do
        not is_list(capability_items) ->
          ["capabilities.#{field} must be a list" | acc]

        true ->
          Enum.reduce(capability_items, acc, &validate_capability_item(&2, kind, &1))
      end
    end)
  end

  defp validate_capabilities(errors, _manifest), do: ["capabilities must be a map" | errors]

  defp validate_capability_item(errors, kind, item) when is_map(item) do
    item = stringify_keys(item)
    name = capability_name(kind, item)

    errors =
      if is_binary(name) and Regex.match?(~r/^[a-z0-9][a-z0-9_.:-]*$/, name) do
        errors
      else
        ["#{kind} capability name is invalid" | errors]
      end

    validate_capability_execution(errors, kind, item)
  end

  defp validate_capability_item(errors, kind, _item),
    do: ["#{kind} capability must be a map" | errors]

  defp validate_capability_execution(errors, "tool", %{"execution" => execution})
       when is_map(execution) do
    execution = stringify_keys(execution)

    if execution["type"] in (@external_execution_types ++ @trusted_execution_types) do
      errors
    else
      ["tool execution.type is unsupported" | errors]
    end
  end

  defp validate_capability_execution(errors, "tool", _item),
    do: ["tool capability requires execution" | errors]

  defp validate_capability_execution(errors, "migration", item) do
    execution = stringify_keys(item["execution"] || %{})

    if execution["type"] in @trusted_execution_types do
      errors
    else
      ["migration capability requires trusted execution" | errors]
    end
  end

  defp validate_capability_execution(errors, "client_surface", item) do
    item = stringify_keys(item)
    entrypoint = stringify_keys(item["entrypoint"] || %{})
    required_scopes = List.wrap(item["required_scopes"] || [])

    errors =
      cond do
        entrypoint == %{} ->
          ["client_surface capability requires entrypoint" | errors]

        entrypoint["type"] not in ["external_url"] ->
          ["client_surface entrypoint.type is unsupported" | errors]

        not valid_client_surface_target?(entrypoint) ->
          ["client_surface entrypoint requires url_env or url" | errors]

        true ->
          errors
      end

    case Enum.reject(required_scopes, &valid_api_scope?/1) do
      [] ->
        errors

      invalid ->
        ["client_surface required_scopes are invalid: #{Enum.join(invalid, ", ")}" | errors]
    end
  end

  defp validate_capability_execution(errors, _kind, _item), do: errors

  defp validate_secret_like_config(errors, manifest) do
    case secret_like_paths(manifest) do
      [] ->
        errors

      paths ->
        [
          "manifest contains inline secret-like keys; use env_refs: #{Enum.join(paths, ", ")}"
          | errors
        ]
    end
  end

  defp normalize_manifest(manifest) do
    permissions =
      manifest
      |> Map.get("permissions", %{})
      |> stringify_keys()
      |> Map.put_new("side_effect_classes", ["read_only"])
      |> Map.put_new("requires_approval", true)
      |> Map.put_new("env_refs", [])
      |> Map.put_new("api_scopes", [])

    manifest
    |> Map.put("permissions", permissions)
    |> Map.put_new("description", "")
    |> Map.put_new("package_type", manifest["plugin_type"] || "runtime_plugin")
    |> Map.put_new("config_schema", %{})
    |> Map.put_new("compatibility", %{})
    |> Map.put_new("dependencies", [])
  end

  defp capability_specs(manifest) do
    capabilities = stringify_keys(manifest["capabilities"] || %{})

    all_capability_fields()
    |> Enum.flat_map(fn {field, kind} ->
      capabilities
      |> Map.get(field, [])
      |> Enum.map(&capability_attrs(kind, &1))
    end)
  end

  defp all_capability_fields, do: Map.merge(@legacy_capability_fields, @capability_fields)

  defp capability_attrs(kind, spec) do
    spec = stringify_keys(spec || %{})

    %{
      "kind" => kind,
      "name" => capability_name(kind, spec),
      "side_effect_class" => spec["side_effect_class"],
      "spec" => spec,
      "metadata" => %{
        "execution_type" => get_in(spec, ["execution", "type"])
      }
    }
  end

  defp capability_name(kind, spec) when kind in ["agent_pack", "skill", "mcp_server"],
    do: spec["slug"] || spec["name"]

  defp capability_name("connector", spec), do: spec["provider"] || spec["name"]
  defp capability_name("room_channel", spec), do: spec["provider"] || spec["name"]
  defp capability_name(_kind, spec), do: spec["name"]

  defp validate_capability_conflicts(workspace_id, manifest, attrs) do
    allow_conflicts? = attrs["allow_name_conflicts"] == true

    conflicts =
      manifest
      |> capability_specs()
      |> Enum.flat_map(&built_in_conflicts/1)

    installed_conflicts =
      manifest
      |> capability_specs()
      |> Enum.flat_map(&installed_conflicts(workspace_id, &1, manifest["slug"]))

    cond do
      allow_conflicts? ->
        :ok

      conflicts != [] or installed_conflicts != [] ->
        {:error,
         %{
           "reason" => "plugin_capability_conflict",
           "conflicts" => conflicts ++ installed_conflicts
         }}

      true ->
        :ok
    end
  end

  defp built_in_conflicts(%{"kind" => "tool", "name" => name}) do
    if name in Registry.names(),
      do: [%{"kind" => "tool", "name" => name, "source" => "core"}],
      else: []
  end

  defp built_in_conflicts(%{"kind" => "tool_bundle", "name" => name}) do
    if name in Bundles.names(),
      do: [%{"kind" => "tool_bundle", "name" => name, "source" => "core"}],
      else: []
  end

  defp built_in_conflicts(_capability), do: []

  defp installed_conflicts(workspace_id, %{"kind" => kind, "name" => name}, plugin_slug) do
    Capability
    |> join(:inner, [capability], plugin in assoc(capability, :plugin_installation))
    |> where(
      [capability, plugin],
      capability.workspace_id == ^normalize_id(workspace_id) and capability.kind == ^kind and
        capability.name == ^name and plugin.slug != ^plugin_slug and
        plugin.status in ["installed", "enabled", "disabled"]
    )
    |> select([capability, plugin], %{
      kind: capability.kind,
      name: capability.name,
      source: plugin.slug
    })
    |> Repo.all()
    |> Enum.map(fn conflict ->
      %{"kind" => conflict.kind, "name" => conflict.name, "source" => conflict.source}
    end)
  end

  defp scan_warnings(manifest) do
    permissions = manifest["permissions"] || %{}

    []
    |> maybe_warning(
      (permissions["side_effect_classes"] || []) -- ["read_only"] != [],
      "plugin requests dangerous side effects"
    )
    |> maybe_warning(
      manifest["trust_level"] == "trusted",
      "plugin requests trusted in-process code"
    )
  end

  defp capability_counts(capabilities) do
    capabilities
    |> Enum.group_by(& &1.kind)
    |> Map.new(fn {kind, items} -> {kind, length(items)} end)
  end

  defp client_plugin_summary(%Installation{} = plugin) do
    manifest = stringify_keys(plugin.manifest || %{})
    permissions = stringify_keys(plugin.permissions || %{})

    %{
      "id" => plugin.id,
      "slug" => plugin.slug,
      "name" => plugin.name,
      "version" => plugin.version,
      "status" => plugin.status,
      "package_type" => manifest["package_type"] || "runtime_plugin",
      "trust_level" => plugin.trust_level,
      "api_scopes" => permissions["api_scopes"] || [],
      "config_schema" => manifest["config_schema"] || %{},
      "compatibility" => manifest["compatibility"] || %{},
      "dependencies" => manifest["dependencies"] || [],
      "config_status" => config_status(plugin),
      "capability_counts" => capability_counts(plugin.capabilities || [])
    }
  end

  defp client_capability_summary(%Capability{} = capability) do
    %{
      "id" => capability.id,
      "plugin_installation_id" => capability.plugin_installation_id,
      "kind" => capability.kind,
      "name" => capability.name,
      "status" => capability.status,
      "side_effect_class" => capability.side_effect_class,
      "metadata" => capability.metadata || %{}
    }
  end

  defp capability_env_refs(capabilities) do
    capabilities
    |> Enum.flat_map(fn capability ->
      capability.spec
      |> stringify_keys()
      |> capability_env_refs_from_value()
    end)
  end

  defp capability_env_refs_from_value(value)

  defp capability_env_refs_from_value(map) when is_map(map) do
    map
    |> stringify_keys()
    |> Enum.flat_map(fn {key, value} ->
      cond do
        env_ref_key?(key) and valid_env_ref?(value) ->
          [value]

        true ->
          capability_env_refs_from_value(value)
      end
    end)
  end

  defp capability_env_refs_from_value(list) when is_list(list),
    do: Enum.flat_map(list, &capability_env_refs_from_value/1)

  defp capability_env_refs_from_value(_value), do: []

  defp plugin_config_schema(%Installation{} = plugin) do
    plugin.manifest
    |> stringify_keys()
    |> Map.get("config_schema", %{})
    |> stringify_keys()
  end

  defp plugin_config(%Installation{} = plugin) do
    plugin
    |> get_configuration()
    |> Map.get(:config, %{})
    |> stringify_keys()
  end

  defp config_status(%Installation{} = plugin) do
    schema = plugin_config_schema(plugin)
    config = plugin_config(plugin)
    required = required_config_keys(schema)
    missing = Enum.reject(required, &Map.has_key?(config, &1))

    cond do
      schema == %{} ->
        %{"status" => "not_required", "missing_required" => []}

      missing == [] ->
        %{"status" => "configured", "missing_required" => []}

      true ->
        %{"status" => "missing_required", "missing_required" => missing}
    end
  end

  defp validate_runtime_config(%Installation{} = plugin, config) when is_map(config) do
    schema = plugin_config_schema(plugin)
    config = stringify_keys(config)

    []
    |> validate_config_secret_like(config)
    |> validate_config_required(schema, config)
    |> validate_config_known_keys(schema, config)
    |> validate_config_types(schema, config)
    |> case do
      [] -> :ok
      errors -> {:error, %{"reason" => "invalid_plugin_config", "errors" => Enum.reverse(errors)}}
    end
  end

  defp validate_runtime_config(_plugin, _config),
    do: {:error, %{"reason" => "invalid_plugin_config", "errors" => ["config must be a map"]}}

  defp validate_config_secret_like(errors, config) do
    case secret_like_paths(config) do
      [] ->
        errors

      paths ->
        ["config contains secret-like keys; use env_refs: #{Enum.join(paths, ", ")}" | errors]
    end
  end

  defp validate_config_required(errors, schema, config) do
    missing = Enum.reject(required_config_keys(schema), &Map.has_key?(config, &1))

    if missing == [],
      do: errors,
      else: ["config missing required keys: #{Enum.join(missing, ", ")}" | errors]
  end

  defp validate_config_known_keys(errors, schema, config) do
    additional? = Map.get(schema, "additional_properties", false)
    properties = schema |> Map.get("properties", %{}) |> stringify_keys()
    unknown = Map.keys(config) -- Map.keys(properties)

    if additional? or unknown == [],
      do: errors,
      else: ["config contains unknown keys: #{Enum.join(unknown, ", ")}" | errors]
  end

  defp validate_config_types(errors, schema, config) do
    properties = schema |> Map.get("properties", %{}) |> stringify_keys()

    Enum.reduce(config, errors, fn {key, value}, acc ->
      property = stringify_keys(properties[key] || %{})

      if property == %{} or config_value_matches_type?(value, property["type"]) do
        acc
      else
        ["config.#{key} must be #{property["type"]}" | acc]
      end
    end)
  end

  defp required_config_keys(schema) do
    schema
    |> Map.get("required", [])
    |> Enum.map(&to_string/1)
  end

  defp config_value_matches_type?(_value, nil), do: true
  defp config_value_matches_type?(value, "string"), do: is_binary(value)
  defp config_value_matches_type?(value, "boolean"), do: is_boolean(value)
  defp config_value_matches_type?(value, "number"), do: is_number(value)
  defp config_value_matches_type?(value, "integer"), do: is_integer(value)
  defp config_value_matches_type?(value, "array"), do: is_list(value)
  defp config_value_matches_type?(value, "object"), do: is_map(value)
  defp config_value_matches_type?(_value, _type), do: true

  defp doctor_status_findings(findings, %Installation{status: "enabled"}), do: findings

  defp doctor_status_findings(findings, %Installation{status: "installed"}) do
    [
      finding(
        "warning",
        "plugin_not_enabled",
        "Plugin is installed but its capabilities are not active."
      )
      | findings
    ]
  end

  defp doctor_status_findings(findings, %Installation{status: "disabled"}) do
    [
      finding(
        "warning",
        "plugin_disabled",
        "Plugin is disabled and unavailable to runtime surfaces."
      )
      | findings
    ]
  end

  defp doctor_status_findings(findings, %Installation{status: "uninstalled"}) do
    [
      finding(
        "error",
        "plugin_uninstalled",
        "Plugin has been uninstalled and should not be used."
      )
      | findings
    ]
  end

  defp doctor_status_findings(findings, %Installation{status: status}) do
    [
      finding(
        "error",
        "plugin_not_ready",
        "Plugin status is #{status}.",
        %{"status" => status}
      )
      | findings
    ]
  end

  defp doctor_env_findings(findings, env_refs) do
    Enum.reduce(env_refs, findings, fn env, acc ->
      case Secrets.fetch_env(env) do
        {:ok, _secret} ->
          acc

        {:error, error} ->
          [
            finding(
              "error",
              "env_ref_missing",
              "Required plugin environment reference is not configured.",
              error
            )
            | acc
          ]
      end
    end)
  end

  defp doctor_manifest_findings(findings, plugin, manifest, permissions) do
    findings
    |> maybe_doctor_finding(
      manifest["plugin_version"] != @manifest_version,
      "error",
      "manifest_version_mismatch",
      "Plugin manifest version does not match this runtime.",
      %{"expected" => @manifest_version, "actual" => manifest["plugin_version"]}
    )
    |> maybe_doctor_finding(
      secret_like_paths(manifest) != [],
      "error",
      "manifest_inline_secret_like_keys",
      "Plugin manifest contains secret-like keys; use environment references.",
      %{"paths" => secret_like_paths(manifest)}
    )
    |> maybe_doctor_finding(
      permissions
      |> Map.get("side_effect_classes", [])
      |> List.wrap()
      |> Enum.any?(&(&1 != "read_only")) and
        Map.get(permissions, "requires_approval", true) == false,
      "error",
      "dangerous_permissions_without_approval",
      "Plugin requests non-read-only side effects without approval.",
      %{"permissions" => permissions}
    )
    |> maybe_doctor_finding(
      plugin.source_type == "git" and not pinned_git_ref?(plugin.source_ref),
      "error",
      "git_ref_not_pinned",
      "Git plugins must be installed from a full commit SHA.",
      %{"source_ref" => plugin.source_ref}
    )
    |> maybe_doctor_finding(
      not version_constraint_satisfied?(
        hydra_version(),
        stringify_keys(manifest["compatibility"] || %{})["hydra_version"]
      ),
      "error",
      "plugin_runtime_incompatible",
      "Plugin compatibility range does not match this Hydra runtime.",
      %{
        "runtime_version" => hydra_version(),
        "constraint" => stringify_keys(manifest["compatibility"] || %{})["hydra_version"]
      }
    )
  end

  defp doctor_config_findings(findings, %Installation{} = plugin) do
    config = plugin_config(plugin)

    case validate_runtime_config(plugin, config) do
      :ok ->
        findings

      {:error, %{"errors" => errors}} ->
        [
          finding(
            "error",
            "plugin_config_invalid",
            "Plugin configuration is missing or invalid.",
            %{"errors" => errors, "status" => config_status(plugin)}
          )
          | findings
        ]
    end
  end

  defp doctor_capability_findings(findings, plugin, capabilities) do
    Enum.reduce(capabilities, findings, fn capability, acc ->
      spec = stringify_keys(capability.spec || %{})
      execution = stringify_keys(spec["execution"] || %{})

      acc
      |> maybe_doctor_finding(
        capability.kind == "migration" and plugin.trust_level != "trusted",
        "error",
        "migration_requires_trusted_plugin",
        "Migration capabilities only run for trusted plugins.",
        %{"capability" => capability.name}
      )
      |> maybe_doctor_finding(
        capability.kind in ["tool", "migration"] and execution["type"] in @trusted_execution_types and
          plugin.trust_level != "trusted",
        "error",
        "trusted_execution_requires_trusted_plugin",
        "Trusted execution is unavailable to external plugins.",
        %{"capability" => capability.name, "execution_type" => execution["type"]}
      )
      |> maybe_doctor_finding(
        capability.kind == "tool" and execution["type"] in ["webhook", "trusted_module"],
        "warning",
        "tool_execution_adapter_fail_closed",
        "This tool adapter is declared but not enabled for execution by the V1 runtime.",
        %{"capability" => capability.name, "execution_type" => execution["type"]}
      )
      |> trusted_module_findings(capability, execution)
    end)
  end

  defp doctor_dependency_findings(findings, %Installation{} = plugin, dependencies) do
    installed_plugins =
      plugin.workspace_id
      |> list_installations()
      |> Enum.reject(&(&1.status == "uninstalled"))
      |> Map.new(&{&1.slug, &1})

    dependencies
    |> Enum.map(&stringify_keys/1)
    |> Enum.reduce(findings, fn dependency, acc ->
      case installed_plugins[dependency["plugin"]] do
        nil ->
          [
            finding(
              "error",
              "plugin_dependency_missing",
              "Required plugin dependency is not installed.",
              dependency
            )
            | acc
          ]

        installed ->
          if version_constraint_satisfied?(installed.version, dependency["version"]) do
            acc
          else
            [
              finding(
                "error",
                "plugin_dependency_version_mismatch",
                "Required plugin dependency version is not satisfied.",
                Map.put(dependency, "installed_version", installed.version)
              )
              | acc
            ]
          end
      end
    end)
  end

  defp trusted_module_findings(findings, capability, %{"type" => type, "module" => module_name})
       when type in @trusted_execution_types do
    case trusted_module(module_name) do
      {:ok, _module} ->
        findings

      {:error, error} ->
        [
          finding(
            "error",
            "trusted_module_not_loaded",
            "Trusted plugin callback module is not loaded.",
            Map.put(error, "capability", capability.name)
          )
          | findings
        ]
    end
  end

  defp trusted_module_findings(findings, _capability, _execution), do: findings

  defp readiness(findings, "enabled") do
    cond do
      Enum.any?(findings, &(&1["severity"] == "error")) -> "needs_attention"
      Enum.any?(findings, &(&1["severity"] == "warning")) -> "setup_pending"
      true -> "ready"
    end
  end

  defp readiness(findings, _status) do
    if Enum.any?(findings, &(&1["severity"] == "error")),
      do: "needs_attention",
      else: "setup_pending"
  end

  defp maybe_doctor_finding(findings, true, severity, code, message, detail),
    do: [finding(severity, code, message, detail) | findings]

  defp maybe_doctor_finding(findings, _condition, _severity, _code, _message, _detail),
    do: findings

  defp finding(severity, code, message, detail \\ %{}) do
    %{
      "severity" => severity,
      "code" => code,
      "message" => message,
      "detail" => detail
    }
  end

  defp require_install_approval(%{"approved_by" => approved_by})
       when is_binary(approved_by) and approved_by != "",
       do: :ok

  defp require_install_approval(_attrs),
    do: {:error, %{"reason" => "plugin_install_approval_required"}}

  defp tool_spec_from_capability(%Capability{} = capability) do
    spec = capability.spec || %{}

    %{
      name: capability.name,
      side_effect_class: capability.side_effect_class || spec["side_effect_class"] || "read_only",
      timeout_ms: spec["timeout_ms"] || 30_000,
      approval_sensitive: Map.get(spec, "approval_sensitive", true),
      parallel_safe: Map.get(spec, "parallel_safe", false),
      description: spec["description"] || "Plugin-provided tool.",
      input_schema: spec["input_schema"] || %{"type" => "object"},
      output_schema: spec["output_schema"] || %{"type" => "object"},
      plugin: %{
        "installation_id" => capability.plugin_installation_id,
        "capability_id" => capability.id,
        "execution" => spec["execution"] || %{}
      }
    }
  end

  defp capability_payload(%Capability{} = capability) do
    capability.spec
    |> Map.put_new("name", capability.name)
    |> Map.put("plugin", %{
      "installation_id" => capability.plugin_installation_id,
      "capability_id" => capability.id
    })
  end

  defp bundle_spec_from_capability(%Capability{} = capability) do
    spec = capability.spec || %{}

    %{
      name: capability.name,
      description: spec["description"] || "Plugin-provided tool bundle.",
      tools: spec["tools"] || [],
      side_effect_classes: spec["side_effect_classes"] || [],
      requires_approval: Map.get(spec, "requires_approval", true),
      approval_sensitive: Map.get(spec, "approval_sensitive", true),
      plugin: %{
        "installation_id" => capability.plugin_installation_id,
        "capability_id" => capability.id
      }
    }
  end

  defp manifest_path(path) do
    cond do
      File.dir?(path) and File.exists?(Path.join([path, ".hydra-plugin", "plugin.json"])) ->
        Path.join([path, ".hydra-plugin", "plugin.json"])

      File.dir?(path) ->
        Path.join(path, "plugin.json")

      true ->
        path
    end
  end

  defp validate_git_source(source_url, source_ref, attrs) do
    cond do
      not is_binary(source_url) or source_url == "" ->
        {:error, %{"reason" => "plugin_git_source_url_required"}}

      not pinned_git_ref?(source_ref) ->
        {:error, %{"reason" => "plugin_git_ref_must_be_full_sha"}}

      not git_url_allowed?(source_url, attrs) ->
        {:error,
         %{
           "reason" => "plugin_git_source_not_allowlisted",
           "source_url" => source_url,
           "git_allowlist" => git_allowlist(attrs)
         }}

      true ->
        :ok
    end
  end

  defp checkout_git_source(source_url, source_ref, attrs) do
    install_root = attrs["install_root"] || plugin_install_root()
    checkout_path = Path.join([install_root, "git", source_ref])

    with :ok <- File.mkdir_p(Path.dirname(checkout_path)),
         :ok <- refresh_checkout(checkout_path, source_url, source_ref),
         {:ok, ^source_ref} <- git_head(checkout_path) do
      {:ok, checkout_path}
    else
      {:ok, actual_ref} ->
        {:error,
         %{
           "reason" => "plugin_git_ref_mismatch",
           "expected_ref" => source_ref,
           "actual_ref" => actual_ref
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp refresh_checkout(checkout_path, source_url, source_ref) do
    File.rm_rf(checkout_path)

    with {_, 0} <- System.cmd("git", ["clone", "--quiet", source_url, checkout_path]),
         {_, 0} <- System.cmd("git", ["checkout", "--quiet", source_ref], cd: checkout_path) do
      :ok
    else
      {output, status} ->
        {:error,
         %{
           "reason" => "plugin_git_checkout_failed",
           "status" => status,
           "output" => output
         }}
    end
  rescue
    error ->
      {:error, %{"reason" => "plugin_git_checkout_failed", "error" => Exception.message(error)}}
  end

  defp git_head(checkout_path) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: checkout_path) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error,
         %{"reason" => "plugin_git_rev_parse_failed", "status" => status, "output" => output}}
    end
  end

  defp pinned_git_ref?(ref) when is_binary(ref), do: Regex.match?(~r/^[a-f0-9]{40}$/, ref)
  defp pinned_git_ref?(_ref), do: false

  defp git_url_allowed?(source_url, attrs) do
    Enum.any?(git_allowlist(attrs), fn prefix ->
      prefix == "*" or String.starts_with?(source_url, prefix)
    end)
  end

  defp git_allowlist(attrs) do
    attrs["git_allowlist"] ||
      Application.get_env(:hydra_agent, :plugin_git_allowlist, [
        "file://",
        "https://github.com/"
      ])
  end

  defp plugin_install_root do
    Application.get_env(
      :hydra_agent,
      :plugin_install_root,
      Path.join(System.tmp_dir!(), "hydra-agent-plugins")
    )
  end

  defp hydra_version do
    :hydra_agent
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp titleize(slug) do
    slug
    |> to_string()
    |> String.replace(~r/[-_]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp secret_like_paths(value, path \\ [])

  defp secret_like_paths(map, path) when is_map(map) do
    map
    |> stringify_keys()
    |> Enum.flat_map(fn {key, value} ->
      current = path ++ [key]

      cond do
        env_ref_key?(key) ->
          secret_like_paths(value, current)

        secret_like_key?(key) ->
          [Enum.join(current, ".")]

        true ->
          secret_like_paths(value, current)
      end
    end)
  end

  defp secret_like_paths(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      secret_like_paths(value, path ++ [to_string(index)])
    end)
  end

  defp secret_like_paths(_value, _path), do: []

  defp secret_like_key?(key) do
    key = String.downcase(to_string(key))

    String.contains?(key, "secret") or String.contains?(key, "token") or
      String.ends_with?(key, "key")
  end

  defp env_ref_key?(key) do
    key = String.downcase(to_string(key))

    key in ["env_refs", "credential_env", "token_env", "secret_env", "api_key_env", "bearer_env"] or
      String.ends_with?(key, "_env")
  end

  defp valid_env_ref?(ref) when is_binary(ref), do: Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, ref)
  defp valid_env_ref?(_ref), do: false

  defp valid_api_scope?(scope) when is_binary(scope) do
    scope in @api_scopes or Regex.match?(~r/^[a-z][a-z0-9_]*:[a-z][a-z0-9_]*$/, scope)
  end

  defp valid_api_scope?(_scope), do: false

  defp valid_dependency_slug?(slug) when is_binary(slug),
    do: Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, slug)

  defp valid_dependency_slug?(_slug), do: false

  defp valid_client_surface_target?(entrypoint) do
    (is_binary(entrypoint["url_env"]) and valid_env_ref?(entrypoint["url_env"])) or
      (is_binary(entrypoint["url"]) and entrypoint["url"] != "")
  end

  defp version_constraint_satisfied?(_version, nil), do: true
  defp version_constraint_satisfied?(_version, ""), do: true

  defp version_constraint_satisfied?(version, constraint)
       when is_binary(version) and is_binary(constraint) do
    constraint
    |> String.split(~r/\s+/, trim: true)
    |> Enum.all?(&single_version_constraint_satisfied?(version, &1))
  end

  defp version_constraint_satisfied?(_version, _constraint), do: false

  defp single_version_constraint_satisfied?(version, constraint) do
    case Regex.run(~r/^(>=|<=|>|<|=)?(.+)$/, constraint) do
      [_match, operator, expected] ->
        operator = if(operator == "", do: "=", else: operator)

        with {:ok, ordering} <- compare_versions(version, expected) do
          case operator do
            "=" -> ordering == :eq
            ">" -> ordering == :gt
            ">=" -> ordering in [:gt, :eq]
            "<" -> ordering == :lt
            "<=" -> ordering in [:lt, :eq]
          end
        else
          _error -> false
        end

      _other ->
        false
    end
  end

  defp compare_versions(left, right) do
    with {:ok, left} <- parse_version(left),
         {:ok, right} <- parse_version(right) do
      {:ok, compare_version_parts(left, right)}
    end
  end

  defp parse_version(version) when is_binary(version) do
    parts =
      version
      |> String.trim()
      |> String.trim_leading("v")
      |> String.split("-", parts: 2)
      |> List.first()
      |> String.split(".")
      |> Enum.map(&Integer.parse/1)

    if Enum.all?(parts, &match?({_integer, ""}, &1)) do
      {:ok, parts |> Enum.map(fn {integer, ""} -> integer end) |> pad_version_parts()}
    else
      :error
    end
  end

  defp parse_version(_version), do: :error

  defp pad_version_parts(parts), do: Enum.take(parts ++ [0, 0, 0], 3)

  defp compare_version_parts(left, right) do
    cond do
      left == right -> :eq
      left > right -> :gt
      true -> :lt
    end
  end

  defp maybe_warning(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_warning(warnings, _condition, _warning), do: warnings

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [row], field(row, ^field) == ^value)

  defp opt(opts, key, default \\ nil) do
    cond do
      is_map(opts) ->
        Map.get(opts, key) || Map.get(opts, to_string(key)) || default

      is_list(opts) ->
        keyword_or_tuple_value(opts, key) || keyword_or_tuple_value(opts, to_string(key)) ||
          default

      true ->
        default
    end
  end

  defp keyword_or_tuple_value(opts, key) do
    case List.keyfind(opts, key, 0) do
      {_key, value} -> value
      nil -> nil
    end
  end

  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalize_id(id), do: id

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{"reason" => "invalid_plugin_record", "errors" => errors_json(changeset)}

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => "plugin_error", "error" => inspect(error)}

  defp errors_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
