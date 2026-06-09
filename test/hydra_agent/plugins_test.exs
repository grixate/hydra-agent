defmodule HydraAgent.PluginsTest do
  use HydraAgent.DataCase

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.{AgentPack, Connectors, Plugins, Rooms, Runtime, Skills}
  alias HydraAgent.Runtime.Authorizer
  alias HydraAgent.Tools.Registry

  test "scans and installs local plugin manifests with approval" do
    workspace = workspace_fixture(%{slug: "plugin-scan-install"})
    plugin_dir = plugin_fixture("echo-tools")

    assert {:ok, scan} = Plugins.scan_path(workspace.id, plugin_dir)
    assert scan["manifest"]["slug"] == "echo-tools"

    assert Enum.any?(
             scan["capabilities"],
             &match?(%{"kind" => "tool", "name" => "plugin_echo"}, &1)
           )

    assert {:error, %{"reason" => "plugin_install_approval_required"}} =
             Plugins.install_from_path(workspace.id, plugin_dir)

    assert {:ok, plugin} =
             Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    assert plugin.status == "installed"
    assert Enum.any?(plugin.capabilities, &(&1.name == "plugin_echo"))
  end

  test "enabled plugin tools participate in policy authorization" do
    workspace = workspace_fixture(%{slug: "plugin-tool-policy"})
    plugin_dir = plugin_fixture("echo-policy")

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    {:ok, _plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert Enum.any?(Registry.all(workspace.id), &(&1.name == "plugin_echo"))

    agent =
      agent_fixture(workspace, %{
        capability_profile: %{
          "tools" => ["plugin_echo"],
          "side_effect_classes" => ["read_only"],
          "approval_policy" => %{"mode" => "required_for_sensitive"}
        }
      })

    {:ok, _policy} =
      Runtime.create_tool_policy(%{
        workspace_id: workspace.id,
        agent_id: agent.id,
        allowed_tools: ["plugin_echo"],
        side_effect_classes: ["read_only"],
        requires_approval: false
      })

    assert {:authorized, %{"tool_name" => "plugin_echo"}} =
             Authorizer.authorize(agent, "plugin_echo", input: %{})
  end

  test "plugin upgrade and uninstall update capabilities" do
    workspace = workspace_fixture(%{slug: "plugin-lifecycle"})
    plugin_dir = plugin_fixture("lifecycle-plugin", version: "0.1.0")

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    {:ok, plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})
    assert Enum.any?(Registry.all(workspace.id), &(&1.name == "plugin_echo"))

    upgraded_dir = plugin_fixture("lifecycle-plugin", version: "0.2.0")

    assert {:ok, upgraded} =
             Plugins.upgrade_from_path(plugin, upgraded_dir, %{"approved_by" => "operator"})

    assert upgraded.version == "0.2.0"
    assert upgraded.status == "enabled"

    assert {:ok, uninstalled} =
             Plugins.uninstall_installation(upgraded, %{"approved_by" => "operator"})

    assert uninstalled.status == "uninstalled"
    refute Enum.any?(Registry.all(workspace.id), &(&1.name == "plugin_echo"))
  end

  test "enabled plugin bundles expand into workspace policies" do
    workspace = workspace_fixture(%{slug: "plugin-bundle-policy"})
    plugin_dir = plugin_fixture("echo-bundle-policy")

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    {:ok, _plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert {:ok, policy} =
             Runtime.create_tool_policy(%{
               workspace_id: workspace.id,
               tool_bundles: ["echo-bundle-policy-bundle"],
               requires_approval: false
             })

    assert "plugin_echo" in policy.allowed_tools
    assert policy.metadata["tool_bundles"] == ["echo-bundle-policy-bundle"]
  end

  test "project-skill plugin tools execute through the registry" do
    workspace = workspace_fixture(%{slug: "plugin-tool-execution"})
    root = skill_workspace_fixture()
    plugin_dir = plugin_fixture("echo-execution")

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    {:ok, _plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert {:ok, %{"exit_status" => 0, "output" => "plugin-skill-ok\n"}} =
             Registry.execute("plugin_echo", %{}, %{
               "workspace_id" => workspace.id,
               "workspace_root" => root
             })
  end

  test "scan rejects plugin capability names that collide with core tools" do
    workspace = workspace_fixture(%{slug: "plugin-conflict"})
    plugin_dir = plugin_fixture("conflict", tool_name: "noop")

    assert {:error, %{"reason" => "plugin_capability_conflict", "conflicts" => conflicts}} =
             Plugins.scan_path(workspace.id, plugin_dir)

    assert %{"kind" => "tool", "name" => "noop", "source" => "core"} in conflicts
  end

  test "git plugin installs require pinned allowlisted refs" do
    workspace = workspace_fixture(%{slug: "plugin-git-install"})
    {:ok, repo, ref} = git_plugin_fixture("git-plugin")
    source_url = "file://#{repo}"

    install_root =
      Path.join(System.tmp_dir!(), "hydra-plugin-install-#{System.unique_integer([:positive])}")

    assert {:error, %{"reason" => "plugin_git_ref_must_be_full_sha"}} =
             Plugins.scan_git(workspace.id, source_url, "main", %{
               "git_allowlist" => ["file://"],
               "install_root" => install_root
             })

    assert {:error, %{"reason" => "plugin_git_source_not_allowlisted"}} =
             Plugins.scan_git(workspace.id, source_url, ref, %{
               "git_allowlist" => ["https://example.com/"],
               "install_root" => install_root
             })

    assert {:ok, plugin} =
             Plugins.install_from_git(workspace.id, source_url, ref, %{
               "approved_by" => "operator",
               "git_allowlist" => ["file://"],
               "install_root" => install_root
             })

    assert plugin.source_type == "git"
    assert plugin.source_ref == ref
    assert plugin.source_url == source_url
  end

  test "enabled non-tool capabilities are discoverable and materialize durable skills" do
    workspace = workspace_fixture(%{slug: "plugin-runtime-assets"})
    plugin_dir = plugin_fixture("runtime-assets", runtime_assets?: true)
    System.put_env("LINEAR_API_KEY", "test-linear-key")

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    {:ok, _plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert [%{"slug" => "plugin-builder"} = pack] = Plugins.enabled_agent_packs(workspace.id)
    assert {:ok, _normalized} = AgentPack.validate_details(pack, workspace_id: workspace.id)

    assert Enum.any?(Connectors.provider_specs(workspace.id), &(&1.provider == "linear"))

    assert {:ok, account} =
             Connectors.create_account(%{
               workspace_id: workspace.id,
               provider: "linear",
               slug: "linear-main",
               display_name: "Linear"
             })

    assert account.provider == "linear"

    assert Enum.any?(
             Rooms.room_channel_specs(workspace.id),
             &((&1["provider"] || &1["name"]) == "discord")
           )

    {:ok, room} =
      Rooms.create_room(%{
        workspace_id: workspace.id,
        title: "Plugin Room",
        slug: "plugin-room"
      })

    assert {:ok, binding} =
             Rooms.create_channel_binding(room, %{
               provider: "discord",
               slug: "discord-main",
               external_chat_id: "discord-channel-1"
             })

    assert binding.provider == "discord"

    assert {:ok, %{user_message: message}} =
             Rooms.send_user_message(room, "/plugin_echo check the runtime",
               source_channel: "telegram"
             )

    assert message.content == "Run plugin echo command.\n\ncheck the runtime"

    assert Enum.any?(
             Skills.list_skills(workspace.id),
             &(&1.slug == "plugin-review" and "plugin_echo" in &1.required_tools)
           )
  end

  test "trusted plugin migrations dry-run before apply" do
    workspace = workspace_fixture(%{slug: "plugin-migrations"})
    plugin_dir = migration_plugin_fixture("migration-plugin")

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    assert {:error, %{"reason" => "plugin_trusted_tier_required"}} =
             Plugins.migration_plan(%{plugin | trust_level: "external"})

    {:ok, trusted_plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{
        "approved_by" => "operator",
        "status" => "enabled"
      })

    trusted_plugin = %{trusted_plugin | trust_level: "trusted"}

    assert {:ok, %{"migration_count" => 1, "plans" => [%{"planned" => true}]}} =
             Plugins.migration_plan(trusted_plugin)

    assert {:error, %{"reason" => "plugin_migration_dry_run_confirmation_required"}} =
             Plugins.run_migrations(trusted_plugin, %{"approved_by" => "operator"})

    assert {:ok, %{"migration_count" => 1, "results" => [%{"applied" => true}]}} =
             Plugins.run_migrations(trusted_plugin, %{
               "approved_by" => "operator",
               "dry_run_confirmed" => true
             })
  end

  test "manifest schema and doctor expose production readiness checks" do
    workspace = workspace_fixture(%{slug: "plugin-doctor"})
    env_ref = "HYDRA_PLUGIN_DOCTOR_MISSING"
    System.delete_env(env_ref)
    plugin_dir = plugin_fixture("doctor-plugin", env_refs: [env_ref])

    assert %{
             "plugin_version" => 1,
             "capability_kinds" => kinds,
             "capability_fields" => %{"client_surfaces" => "client_surface"},
             "legacy_capability_fields" => %{"web_routes" => "client_surface"},
             "package_types" => package_types,
             "api_scopes" => api_scopes,
             "source_security" => %{"git_source_ref" => "full 40-character commit SHA"}
           } = Plugins.manifest_schema()

    assert "client_surface" in kinds
    assert "client_app" in package_types
    assert "plugins:read" in api_scopes

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    report = Plugins.doctor(plugin)

    assert report["readiness"] == "needs_attention"
    assert report["capability_counts"]["tool"] == 1
    assert Enum.any?(report["findings"], &(&1["code"] == "env_ref_missing"))
  end

  test "enabled client surface capabilities are discoverable without mounting plugin code" do
    workspace = workspace_fixture(%{slug: "plugin-client-surfaces"})
    plugin_dir = plugin_fixture("surface-plugin", client_surfaces?: true)

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    assert Plugins.enabled_client_surface_specs(workspace.id) == []

    {:ok, _plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert [
             %{
               "name" => "design-studio",
               "kind" => "external_url",
               "path" => "/plugins/design-studio",
               "surface" => "workspace",
               "required_scopes" => ["workspaces:read", "runs:read"]
             }
           ] = Plugins.enabled_client_surface_specs(workspace.id)

    assert Plugins.enabled_web_route_specs(workspace.id) ==
             Plugins.enabled_client_surface_specs(workspace.id)
  end

  test "legacy web_routes manifests map to client surfaces" do
    workspace = workspace_fixture(%{slug: "plugin-legacy-web-routes"})
    plugin_dir = plugin_fixture("legacy-surface-plugin", legacy_web_routes?: true)

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    {:ok, _plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert [%{"name" => "legacy-studio"}] = Plugins.enabled_client_surface_specs(workspace.id)
  end

  test "client contract summarizes plugin state for separate management apps" do
    workspace = workspace_fixture(%{slug: "plugin-client-contract"})
    plugin_dir = plugin_fixture("contract-plugin", client_surfaces?: true)

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    {:ok, _plugin} = Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert %{
             "plugins" => [%{"slug" => "contract-plugin", "package_type" => "hybrid"}],
             "client_surfaces" => [%{"name" => "design-studio"}],
             "manifest_schema" => %{"capability_fields" => %{"client_surfaces" => _}}
           } = Plugins.client_contract(workspace.id)
  end

  test "required non-secret config must be valid before enable" do
    workspace = workspace_fixture(%{slug: "plugin-config-hardening"})

    plugin_dir =
      plugin_fixture("config-plugin",
        config_schema: %{
          "type" => "object",
          "properties" => %{"team_id" => %{"type" => "string"}},
          "required" => ["team_id"]
        }
      )

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    assert {:error, %{"reason" => "plugin_not_ready_for_enable", "findings" => findings}} =
             Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert Enum.any?(findings, &(&1["code"] == "plugin_config_invalid"))

    assert {:error, %{"reason" => "invalid_plugin_config", "errors" => errors}} =
             Plugins.update_configuration(plugin, %{
               "config" => %{"team_id" => 42},
               "configured_by" => "operator"
             })

    assert "config.team_id must be string" in errors

    assert {:ok, configuration} =
             Plugins.update_configuration(plugin, %{
               "config" => %{"team_id" => "eng"},
               "configured_by" => "operator"
             })

    assert configuration.config == %{"team_id" => "eng"}

    assert {:ok, enabled} =
             Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert enabled.status == "enabled"
    assert Plugins.doctor(enabled)["config_status"]["status"] == "configured"
  end

  test "compatibility metadata is enforced at scan time" do
    workspace = workspace_fixture(%{slug: "plugin-compatibility"})

    plugin_dir =
      plugin_fixture("future-plugin", compatibility: %{"hydra_version" => ">=9.0.0"})

    assert {:error, %{"reason" => "invalid_plugin_manifest", "errors" => errors}} =
             Plugins.scan_path(workspace.id, plugin_dir)

    assert "compatibility.hydra_version does not match runtime 0.1.0" in errors
  end

  test "dependencies are enforced before enable" do
    workspace = workspace_fixture(%{slug: "plugin-dependencies"})

    plugin_dir =
      plugin_fixture("dependent-plugin",
        dependencies: [%{"plugin" => "missing-plugin", "version" => ">=1.0.0"}]
      )

    {:ok, plugin} =
      Plugins.install_from_path(workspace.id, plugin_dir, %{"approved_by" => "operator"})

    assert {:error, %{"reason" => "plugin_not_ready_for_enable", "findings" => findings}} =
             Plugins.enable_installation(plugin, %{"approved_by" => "operator"})

    assert Enum.any?(findings, &(&1["code"] == "plugin_dependency_missing"))
  end

  test "bundled example plugin manifests validate" do
    workspace = workspace_fixture(%{slug: "plugin-examples"})

    for path <-
          "plugins/examples/*"
          |> Path.wildcard()
          |> Enum.filter(&File.exists?(Path.join([&1, ".hydra-plugin", "plugin.json"]))) do
      assert {:ok, scan} = Plugins.scan_path(workspace.id, path)
      assert scan["manifest"]["plugin_version"] == 1
      assert scan["capabilities"] != []
    end
  end

  defp plugin_fixture(slug, opts \\ []) do
    root = Path.join(System.tmp_dir!(), "hydra-plugin-#{System.unique_integer([:positive])}")
    plugin_dir = Path.join(root, slug)
    manifest_dir = Path.join(plugin_dir, ".hydra-plugin")
    File.mkdir_p!(manifest_dir)

    tool_name = Keyword.get(opts, :tool_name, "plugin_echo")

    manifest = %{
      "plugin_version" => 1,
      "slug" => slug,
      "name" => "Echo Tools",
      "version" => Keyword.get(opts, :version, "0.1.0"),
      "description" => "Test plugin.",
      "package_type" =>
        if(Keyword.get(opts, :client_surfaces?, false), do: "hybrid", else: "runtime_plugin"),
      "trust_level" => "external",
      "permissions" => %{
        "side_effect_classes" => ["read_only"],
        "requires_approval" => true,
        "env_refs" => Keyword.get(opts, :env_refs, []),
        "api_scopes" => Keyword.get(opts, :api_scopes, ["plugins:read"])
      },
      "config_schema" =>
        Keyword.get(opts, :config_schema, %{
          "type" => "object",
          "properties" => %{"mode" => %{"type" => "string"}},
          "required" => []
        }),
      "compatibility" =>
        Keyword.get(opts, :compatibility, %{"hydra_version" => ">=0.1.0 <0.2.0"}),
      "dependencies" => Keyword.get(opts, :dependencies, []),
      "capabilities" => %{
        "tools" => [
          %{
            "name" => tool_name,
            "description" => "Echo through a project skill adapter.",
            "side_effect_class" => "read_only",
            "input_schema" => %{"type" => "object"},
            "output_schema" => %{"type" => "object"},
            "execution" => %{
              "type" => "project_skill",
              "skill_slug" => "echo",
              "entrypoint" => "scripts/run.sh",
              "runtime" => "shell"
            }
          }
        ],
        "tool_bundles" => [
          %{
            "name" => "#{slug}-bundle",
            "description" => "Echo bundle.",
            "tools" => [tool_name],
            "side_effect_classes" => ["read_only"],
            "requires_approval" => false
          }
        ],
        "agent_packs" => agent_packs(opts),
        "skills" => skill_specs(opts),
        "mcp_servers" => mcp_server_specs(opts),
        "connectors" => connector_specs(opts),
        "room_channels" => room_channel_specs(opts),
        "cli_commands" => cli_command_specs(opts),
        "client_surfaces" => client_surface_specs(opts),
        "web_routes" => legacy_web_route_specs(opts),
        "migrations" => []
      }
    }

    File.write!(Path.join(manifest_dir, "plugin.json"), Jason.encode!(manifest))
    plugin_dir
  end

  defp git_plugin_fixture(slug) do
    repo =
      Path.join(System.tmp_dir!(), "hydra-plugin-git-src-#{System.unique_integer([:positive])}")

    plugin_dir = Path.join(repo, ".hydra-plugin")
    File.mkdir_p!(plugin_dir)
    source_plugin_dir = plugin_fixture(slug)

    File.cp!(
      Path.join([source_plugin_dir, ".hydra-plugin", "plugin.json"]),
      Path.join(plugin_dir, "plugin.json")
    )

    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: repo)
    {_, 0} = System.cmd("git", ["add", ".hydra-plugin/plugin.json"], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", "plugin"], cd: repo)
    {ref, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    {:ok, repo, String.trim(ref)}
  end

  defp agent_packs(runtime_assets?: true) do
    [
      %{
        "name" => "Plugin Builder",
        "slug" => "plugin-builder",
        "agent_pack_version" => 1,
        "role" => "builder",
        "description" => "Builds with plugin tools.",
        "model_route" => %{},
        "tools" => [],
        "tool_bundles" => ["runtime-assets-bundle"],
        "skills" => ["plugin-review"],
        "memory_scopes" => ["workspace"],
        "knowledge_scopes" => ["workspace"],
        "permissions" => %{"side_effect_classes" => ["read_only"], "requires_approval" => true},
        "autonomy" => %{"level" => "recommend"},
        "approval_policy" => %{"mode" => "required_for_sensitive"}
      }
    ]
  end

  defp agent_packs(_opts), do: []

  defp skill_specs(runtime_assets?: true) do
    [
      %{
        "name" => "Plugin Review",
        "slug" => "plugin-review",
        "description" => "Review plugin-provided work.",
        "instructions" => "Use plugin_echo when verification needs a plugin tool.",
        "required_tools" => ["plugin_echo"],
        "memory_scopes" => ["workspace"],
        "knowledge_scopes" => ["workspace"]
      }
    ]
  end

  defp skill_specs(_opts), do: []

  defp connector_specs(runtime_assets?: true) do
    [
      %{
        "name" => "linear",
        "provider" => "linear",
        "label" => "Linear",
        "capabilities" => ["linear.search", "linear.create_issue"],
        "write_actions" => ["create_issue"],
        "setup" => %{"credential_env" => "LINEAR_API_KEY", "config_fields" => ["team_id"]}
      }
    ]
  end

  defp connector_specs(_opts), do: []

  defp room_channel_specs(runtime_assets?: true) do
    [
      %{
        "name" => "discord",
        "provider" => "discord",
        "label" => "Discord",
        "delivery" => "webhook"
      }
    ]
  end

  defp room_channel_specs(_opts), do: []

  defp mcp_server_specs(runtime_assets?: true) do
    [
      %{
        "name" => "plugin-docs",
        "slug" => "plugin-docs",
        "transport" => "http",
        "config" => %{"url" => "https://mcp.example.com"},
        "include_tools" => ["search"]
      }
    ]
  end

  defp mcp_server_specs(_opts), do: []

  defp cli_command_specs(runtime_assets?: true) do
    [
      %{
        "name" => "plugin_echo",
        "command" => "/plugin_echo",
        "description" => "Run plugin echo.",
        "prompt" => "Run plugin echo command."
      }
    ]
  end

  defp cli_command_specs(_opts), do: []

  defp client_surface_specs(client_surfaces?: true) do
    [
      %{
        "name" => "design-studio",
        "kind" => "external_url",
        "path" => "/plugins/design-studio",
        "surface" => "workspace",
        "required_scopes" => ["workspaces:read", "runs:read"],
        "entrypoint" => %{"type" => "external_url", "url" => "http://localhost:4101"}
      }
    ]
  end

  defp client_surface_specs(_opts), do: []

  defp legacy_web_route_specs(legacy_web_routes?: true) do
    [
      %{
        "name" => "legacy-studio",
        "kind" => "external_url",
        "path" => "/plugins/legacy-studio",
        "surface" => "workspace",
        "entrypoint" => %{"type" => "external_url", "url" => "http://localhost:4102"}
      }
    ]
  end

  defp legacy_web_route_specs(_opts), do: []

  defp skill_workspace_fixture do
    root =
      Path.join(System.tmp_dir!(), "hydra-plugin-skill-#{System.unique_integer([:positive])}")

    script_dir = Path.join([root, ".hydra", "skills", "echo", "scripts"])
    File.mkdir_p!(script_dir)
    File.write!(Path.join(script_dir, "run.sh"), "printf 'plugin-skill-ok\\n'\n")
    root
  end

  defp migration_plugin_fixture(slug) do
    root =
      Path.join(System.tmp_dir!(), "hydra-plugin-migration-#{System.unique_integer([:positive])}")

    manifest_dir = Path.join([root, ".hydra-plugin"])
    File.mkdir_p!(manifest_dir)

    manifest = %{
      "plugin_version" => 1,
      "slug" => slug,
      "name" => "Migration Plugin",
      "version" => "0.1.0",
      "trust_level" => "trusted",
      "permissions" => %{
        "side_effect_classes" => ["workspace_write"],
        "requires_approval" => true,
        "env_refs" => []
      },
      "capabilities" => %{
        "tools" => [],
        "tool_bundles" => [],
        "agent_packs" => [],
        "skills" => [],
        "mcp_servers" => [],
        "connectors" => [],
        "room_channels" => [],
        "cli_commands" => [],
        "client_surfaces" => [],
        "migrations" => [
          %{
            "name" => "seed-plugin-state",
            "description" => "Seed plugin state.",
            "execution" => %{
              "type" => "trusted_module",
              "module" => "HydraAgent.TestPluginMigration"
            }
          }
        ]
      }
    }

    File.write!(Path.join(manifest_dir, "plugin.json"), Jason.encode!(manifest))
    root
  end
end

defmodule HydraAgent.TestPluginMigration do
  @behaviour HydraAgent.Plugin.Migration

  @impl true
  def plan(_context), do: {:ok, %{"planned" => true}}

  @impl true
  def run(_context), do: {:ok, %{"applied" => true}}
end
