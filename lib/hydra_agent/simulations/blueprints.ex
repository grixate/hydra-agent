defmodule HydraAgent.Simulations.Blueprints do
  @moduledoc "Blueprint library, immutable versioning, portability, and deterministic testing."

  import Ecto.Query

  alias Ecto.Multi
  alias HydraAgent.Accounts.User
  alias HydraAgent.ProductFeatures
  alias HydraAgent.Repo
  alias HydraAgent.Runtime.Workspace

  alias HydraAgent.Simulations.{
    Blueprint,
    BlueprintPackage,
    BlueprintTester,
    BlueprintVersion,
    BuiltInBlueprints
  }

  def list_blueprints(workspace_id, opts \\ []) do
    workspace_id = normalize_id(workspace_id)
    status = Keyword.get(opts, :status, "active")

    Blueprint
    |> where(
      [blueprint],
      (is_nil(blueprint.workspace_id) and blueprint.built_in) or
        blueprint.workspace_id == ^workspace_id
    )
    |> maybe_filter_status(status)
    |> order_by(
      [blueprint],
      desc: blueprint.built_in,
      asc:
        fragment(
          "CASE ? WHEN 'general-agent-simulation' THEN 0 WHEN 'decision-replay' THEN 1 ELSE 2 END",
          blueprint.slug
        ),
      asc: blueprint.slug
    )
    |> preload([:active_version])
    |> Repo.all()
  end

  def source_version(%Blueprint{source_blueprint_id: nil}), do: nil

  def source_version(%Blueprint{source_blueprint_id: source_blueprint_id}) do
    Blueprint
    |> Repo.get(source_blueprint_id)
    |> case do
      nil -> nil
      source -> source |> Repo.preload(:active_version) |> Map.get(:active_version)
    end
  end

  def get_blueprint_for_workspace(workspace_id, id) do
    workspace_id = normalize_id(workspace_id)
    id = normalize_id(id)

    Blueprint
    |> where(
      [blueprint],
      blueprint.id == ^id and
        ((is_nil(blueprint.workspace_id) and blueprint.built_in) or
           blueprint.workspace_id == ^workspace_id)
    )
    |> preload([
      :active_version,
      versions: ^from(v in BlueprintVersion, order_by: [desc: v.inserted_at])
    ])
    |> Repo.one()
  end

  def get_blueprint_for_workspace!(workspace_id, id) do
    get_blueprint_for_workspace(workspace_id, id) ||
      raise Ecto.NoResultsError, queryable: Blueprint
  end

  def import_blueprint(%Workspace{} = workspace, user, binary) do
    if ProductFeatures.enabled?(:blueprint_import) do
      with :ok <- authorize_editor(user, workspace),
           {:ok, package} <- BlueprintPackage.import(binary) do
        create_from_package(workspace, user, package, %{
          "kind" => "imported",
          "content_hash" => package.content_hash
        })
      end
    else
      {:error, :blueprint_import_disabled}
    end
  end

  @doc "Reuses an exact portable Blueprint or imports a conflict-safe workspace copy."
  def ensure_portable_blueprint(%Workspace{} = workspace, user, binary) when is_binary(binary) do
    with :ok <- authorize_editor(user, workspace),
         {:ok, package} <- BlueprintPackage.import(binary) do
      case exact_active_blueprint(workspace.id, package.content_hash) do
        %Blueprint{} = blueprint ->
          {:ok, blueprint}

        nil ->
          if ProductFeatures.enabled?(:blueprint_import) do
            source_content_hash = package.content_hash
            package = avoid_portable_slug_conflict(workspace.id, package)

            create_from_package(workspace, user, package, %{
              "kind" => "simulation_pack_import",
              "content_hash" => package.content_hash,
              "source_content_hash" => source_content_hash
            })
          else
            {:error, :blueprint_import_disabled}
          end
      end
    end
  end

  def duplicate_blueprint(
        %Blueprint{} = source,
        %Workspace{} = workspace,
        user,
        attrs \\ %{}
      ) do
    with :ok <- authorize_editor(user, workspace),
         :ok <- ensure_blueprint_visible(source, workspace),
         source <- Repo.preload(source, :active_version),
         %BlueprintVersion{} = source_version <- source.active_version do
      slug = attrs[:slug] || attrs["slug"] || available_copy_slug(workspace.id, source.slug)
      name = attrs[:name] || attrs["name"] || copied_name(source.name)
      description = attrs[:description] || attrs["description"] || source.description

      manifest =
        source_version.manifest
        |> Map.drop(["files", "content_hash", "imported_origin"])
        |> Map.merge(%{
          "id" => slug,
          "name" => name,
          "description" => description,
          "version" => "1.0.0"
        })

      with {:ok, package} <-
             BlueprintPackage.from_components(%{
               manifest: manifest,
               instructions: source_version.instructions,
               schemas: source_version.schemas,
               examples: source_version.examples,
               readme: source_version.readme
             }) do
        create_from_package(workspace, user, package, %{
          "kind" => "duplicated",
          "source_blueprint_id" => source.id,
          "source_content_hash" => source_version.content_hash
        })
      end
    else
      nil -> {:error, :blueprint_has_no_active_version}
      {:error, _reason} = error -> error
    end
  end

  def create_version(%Blueprint{built_in: true}, _user, _components),
    do: {:error, :built_in_read_only}

  def create_version(%Blueprint{} = blueprint, user, components) do
    blueprint = Repo.preload(blueprint, :active_version)

    with :ok <- authorize_blueprint_editor(user, blueprint),
         {:ok, package} <- BlueprintPackage.from_components(components),
         :ok <- ensure_manifest_identity(blueprint, package),
         :ok <- ensure_newer_version(blueprint.active_version, package),
         :ok <- ensure_new_content(blueprint.active_version, package) do
      Repo.transaction(fn ->
        version = insert_version!(Repo, blueprint, user_id(user), package)

        blueprint
        |> Blueprint.activate_version_changeset(version.id, package.manifest)
        |> Repo.update!()
        |> Repo.preload(:active_version, force: true)
      end)
      |> unwrap_transaction()
    end
  end

  def archive_blueprint(%Blueprint{built_in: true}, _user), do: {:error, :built_in_read_only}

  def archive_blueprint(%Blueprint{} = blueprint, user) do
    with :ok <- authorize_blueprint_editor(user, blueprint) do
      blueprint |> Blueprint.archive_changeset() |> Repo.update()
    end
  end

  def export_blueprint(%Blueprint{} = blueprint) do
    blueprint = Repo.preload(blueprint, :active_version)

    case blueprint.active_version do
      %BlueprintVersion{} = version -> BlueprintPackage.export(version)
      nil -> {:error, :blueprint_has_no_active_version}
    end
  end

  def test_blueprint(%Blueprint{} = blueprint) do
    blueprint = Repo.preload(blueprint, :active_version)

    case blueprint.active_version do
      %BlueprintVersion{} = version -> BlueprintTester.run(version)
      nil -> {:error, :blueprint_has_no_active_version}
    end
  end

  def ensure_builtins! do
    Repo.transaction(fn ->
      Enum.map(BuiltInBlueprints.all(), &ensure_builtin!(&1))
    end)
    |> case do
      {:ok, blueprints} -> blueprints
      {:error, reason} -> raise "could not provision built-in Blueprints: #{inspect(reason)}"
    end
  end

  defp ensure_builtin!(package) do
    slug = package.manifest["id"]
    version_number = package.manifest["version"]

    blueprint_query =
      from blueprint in Blueprint,
        where: blueprint.slug == ^slug and blueprint.built_in and is_nil(blueprint.workspace_id)

    case Repo.one(blueprint_query) do
      nil ->
        create_builtin!(package)

      blueprint ->
        case Repo.get_by(BlueprintVersion, blueprint_id: blueprint.id, version: version_number) do
          nil ->
            version = insert_version!(Repo, blueprint, nil, package)
            activate!(blueprint, version, package)

          %BlueprintVersion{content_hash: hash} = version when hash == package.content_hash ->
            if blueprint.active_version_id == version.id,
              do: Repo.preload(blueprint, :active_version),
              else: activate!(blueprint, version, package)

          _version ->
            Repo.rollback({:built_in_version_changed_without_semver_bump, slug, version_number})
        end
    end
  end

  defp create_builtin!(package) do
    blueprint =
      %Blueprint{}
      |> Blueprint.create_changeset(%{
        slug: package.manifest["id"],
        name: package.manifest["name"],
        description: package.manifest["description"],
        built_in: true,
        status: "active",
        origin: %{"kind" => "built_in"}
      })
      |> Repo.insert!()

    version = insert_version!(Repo, blueprint, nil, package)
    activate!(blueprint, version, package)
  end

  defp create_from_package(%Workspace{} = workspace, user, package, origin) do
    source_blueprint_id = origin["source_blueprint_id"]

    Multi.new()
    |> Multi.insert(
      :blueprint,
      Blueprint.create_changeset(%Blueprint{}, %{
        workspace_id: workspace.id,
        owner_user_id: user_id(user),
        source_blueprint_id: source_blueprint_id,
        slug: package.manifest["id"],
        name: package.manifest["name"],
        description: package.manifest["description"],
        built_in: false,
        status: "active",
        origin: Map.delete(origin, "source_blueprint_id")
      })
    )
    |> Multi.insert(:version, fn %{blueprint: blueprint} ->
      BlueprintVersion.create_changeset(
        %BlueprintVersion{},
        version_attrs(blueprint, user_id(user), package)
      )
    end)
    |> Multi.update(:activate, fn %{blueprint: blueprint, version: version} ->
      Blueprint.activate_version_changeset(blueprint, version.id, package.manifest)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{activate: blueprint}} -> {:ok, Repo.preload(blueprint, :active_version)}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  defp insert_version!(repo, blueprint, created_by_user_id, package) do
    %BlueprintVersion{}
    |> BlueprintVersion.create_changeset(version_attrs(blueprint, created_by_user_id, package))
    |> repo.insert!()
  end

  defp version_attrs(blueprint, created_by_user_id, package) do
    %{
      workspace_id: blueprint.workspace_id,
      blueprint_id: blueprint.id,
      created_by_user_id: created_by_user_id,
      version: package.manifest["version"],
      manifest: package.manifest,
      instructions: package.instructions,
      schemas: package.schemas,
      examples: package.examples,
      readme: package.readme,
      capability_requirements: package.manifest["capabilities"] || %{},
      content_hash: package.content_hash,
      validation_status: "valid",
      validation_errors: package.validation_errors,
      compatibility_warnings: package.compatibility_warnings
    }
  end

  defp activate!(blueprint, version, package) do
    blueprint
    |> Blueprint.activate_version_changeset(version.id, package.manifest)
    |> Repo.update!()
    |> Repo.preload(:active_version, force: true)
  end

  defp authorize_editor(nil, _workspace) do
    if HydraAgent.Accounts.browser_auth_enabled?(), do: {:error, :forbidden}, else: :ok
  end

  defp authorize_editor(%User{} = user, %Workspace{} = workspace) do
    if HydraAgent.Accounts.workspace_authorized?(user, workspace.id, "researcher"),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp authorize_blueprint_editor(user, %Blueprint{workspace_id: workspace_id}) do
    case Repo.get(Workspace, workspace_id) do
      nil -> {:error, :workspace_not_found}
      workspace -> authorize_editor(user, workspace)
    end
  end

  defp ensure_blueprint_visible(%Blueprint{built_in: true, workspace_id: nil}, _workspace),
    do: :ok

  defp ensure_blueprint_visible(%Blueprint{workspace_id: workspace_id}, %Workspace{
         id: workspace_id
       }),
       do: :ok

  defp ensure_blueprint_visible(_blueprint, _workspace), do: {:error, :forbidden}

  defp ensure_manifest_identity(blueprint, package) do
    if package.manifest["id"] == blueprint.slug,
      do: :ok,
      else: {:error, :manifest_id_mismatch}
  end

  defp exact_active_blueprint(workspace_id, content_hash) do
    Blueprint
    |> join(:inner, [blueprint], version in BlueprintVersion,
      on: version.id == blueprint.active_version_id
    )
    |> where(
      [blueprint, version],
      version.content_hash == ^content_hash and blueprint.status == "active" and
        ((blueprint.built_in and is_nil(blueprint.workspace_id)) or
           blueprint.workspace_id == ^workspace_id)
    )
    |> preload([:active_version])
    |> Repo.one()
  end

  defp avoid_portable_slug_conflict(workspace_id, package) do
    slug = package.manifest["id"]

    conflict? =
      Repo.exists?(
        from blueprint in Blueprint,
          where: blueprint.workspace_id == ^workspace_id and blueprint.slug == ^slug
      )

    if conflict? do
      portable_slug = available_import_slug(workspace_id, slug)

      {:ok, renamed} =
        BlueprintPackage.from_components(%{
          manifest: Map.put(package.manifest, "id", portable_slug),
          instructions: package.instructions,
          schemas: package.schemas,
          examples: package.examples,
          readme: package.readme
        })

      renamed
    else
      package
    end
  end

  defp available_import_slug(workspace_id, source_slug) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn number ->
      suffix = if number == 1, do: "portable", else: "portable-#{number}"
      candidate = String.slice("#{source_slug}-#{suffix}", 0, 100)

      unless Repo.exists?(
               from blueprint in Blueprint,
                 where: blueprint.workspace_id == ^workspace_id and blueprint.slug == ^candidate
             ),
             do: candidate
    end)
  end

  defp ensure_newer_version(nil, _package), do: :ok

  defp ensure_newer_version(active, package) do
    if Version.compare(package.manifest["version"], active.version) == :gt,
      do: :ok,
      else: {:error, :version_must_increase}
  end

  defp ensure_new_content(nil, _package), do: :ok

  defp ensure_new_content(active, package) do
    if active.content_hash == package.content_hash,
      do: {:error, :content_unchanged},
      else: :ok
  end

  defp copied_name(name) do
    %{
      "en" => String.slice((name["en"] || "Blueprint") <> " copy", 0, 100),
      "ru" => String.slice("Копия — " <> (name["ru"] || "Шаблон"), 0, 100)
    }
  end

  defp available_copy_slug(workspace_id, source_slug) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn number ->
      suffix = if number == 1, do: "copy", else: "copy-#{number}"
      candidate = String.slice("#{source_slug}-#{suffix}", 0, 100)

      unless Repo.exists?(
               from blueprint in Blueprint,
                 where: blueprint.workspace_id == ^workspace_id and blueprint.slug == ^candidate
             ),
             do: candidate
    end)
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [blueprint], blueprint.status == ^status)

  defp user_id(%User{id: id}), do: id
  defp user_id(nil), do: nil

  defp normalize_id(value) when is_integer(value), do: value

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> -1
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
