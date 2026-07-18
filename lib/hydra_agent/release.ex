defmodule HydraAgent.Release do
  @moduledoc false

  @app :hydra_agent
  @workspace_roles ~w(viewer researcher admin owner)

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _started, _stopped} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _started, _stopped} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Provisions a workspace-scoped user without placing a password in the command.

  `password_env` names an environment variable containing the initial password.
  Existing users keep their verifier and receive only the requested membership.
  """
  def provision_workspace_user(email, password_env, workspace_slug, role)
      when is_binary(email) and is_binary(password_env) and is_binary(workspace_slug) and
             role in @workspace_roles do
    load_app()

    password =
      System.get_env(password_env) ||
        raise "environment variable #{password_env} is required for user provisioning"

    {:ok, result, _stopped} =
      Ecto.Migrator.with_repo(HydraAgent.Repo, fn repo ->
        repo.transaction(fn ->
          workspace = repo.get_by!(HydraAgent.Runtime.Workspace, slug: workspace_slug)

          user =
            HydraAgent.Accounts.get_user_by_email(email) ||
              case HydraAgent.Accounts.create_user(%{
                     email: email,
                     password: password,
                     display_name: email |> String.split("@") |> hd()
                   }) do
                {:ok, user} -> user
                {:error, reason} -> repo.rollback(reason)
              end

          case HydraAgent.Accounts.add_workspace_member(user, workspace, role) do
            {:ok, membership} -> %{user_id: user.id, membership_id: membership.id, role: role}
            {:error, changeset} -> repo.rollback(changeset)
          end
        end)
      end)

    result
  end

  def provision_workspace_user(_email, _password_env, _workspace_slug, role),
    do: raise("unsupported workspace role: #{inspect(role)}")

  @doc "Reset a user's password from an environment variable and revoke browser sessions."
  def reset_user_password(email, password_env)
      when is_binary(email) and is_binary(password_env) do
    load_app()

    password =
      System.get_env(password_env) ||
        raise "environment variable #{password_env} is required for password reset"

    {:ok, result, _stopped} =
      Ecto.Migrator.with_repo(HydraAgent.Repo, fn _repo ->
        user = HydraAgent.Accounts.get_user_by_email(email) || raise "user not found"

        case HydraAgent.Accounts.reset_password(user, password) do
          {:ok, updated} ->
            HydraAgentWeb.UserAuth.disconnect_user_live_sessions(user)
            %{user_id: updated.id, sessions_revoked: true}

          {:error, reason} ->
            raise "password reset failed: #{inspect(reason)}"
        end
      end)

    result
  end

  @doc "Issue a one-time visible, hashed API token scoped to a workspace or global operations."
  def issue_api_token(name, workspace_slug, permissions, expires_in_days \\ 90)
      when is_binary(name) and is_binary(workspace_slug) and is_list(permissions) and
             is_integer(expires_in_days) and expires_in_days > 0 do
    load_app()

    unless HydraAgent.ApiCredentials.valid_permissions?(permissions),
      do: raise("permissions must contain read and/or write")

    {:ok, result, _stopped} =
      Ecto.Migrator.with_repo(HydraAgent.Repo, fn repo ->
        workspace_id =
          case workspace_slug do
            "global" -> nil
            slug -> repo.get_by!(HydraAgent.Runtime.Workspace, slug: slug).id
          end

        expires_at = DateTime.add(DateTime.utc_now(), expires_in_days, :day)

        case HydraAgent.ApiCredentials.issue_token(%{
               name: name,
               workspace_id: workspace_id,
               permissions: permissions,
               expires_at: expires_at
             }) do
          {:ok, %{token: token, record: record}} ->
            %{
              token: token,
              prefix: record.token_prefix,
              workspace_id: workspace_id,
              permissions: permissions,
              expires_at: expires_at
            }

          {:error, reason} ->
            raise "API token issuance failed: #{inspect(reason)}"
        end
      end)

    result
  end

  @doc "Revoke a database-backed API token by its non-secret prefix."
  def revoke_api_token(prefix) when is_binary(prefix) do
    load_app()

    {:ok, result, _stopped} =
      Ecto.Migrator.with_repo(HydraAgent.Repo, fn _repo ->
        case HydraAgent.ApiCredentials.revoke_by_prefix(prefix) do
          :ok -> %{prefix: prefix, revoked: true}
          {:error, :not_found} -> raise "active API token not found"
        end
      end)

    result
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.load(@app)
  end
end
