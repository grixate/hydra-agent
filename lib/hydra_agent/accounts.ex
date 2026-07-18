defmodule HydraAgent.Accounts do
  @moduledoc """
  Local operator identities and explicit workspace access.

  Hydra is self-hosted, so identity is intentionally small and inspectable:
  password verifiers live in the database, bootstrap credentials stay in the
  environment, and every non-system user receives an explicit workspace role.
  """

  import Ecto.Query

  alias HydraAgent.Accounts.{User, WorkspaceMembership}
  alias HydraAgent.Repo
  alias HydraAgent.Runtime.Workspace

  @iterations 210_000
  @salt_bytes 16
  @derived_bytes 32
  @role_rank %{"viewer" => 0, "researcher" => 1, "admin" => 2, "owner" => 3}
  def create_user(attrs) do
    attrs = Map.new(attrs)
    password = fetch(attrs, :password)

    with :ok <- validate_password(password) do
      attrs =
        attrs
        |> Map.delete(:password)
        |> Map.delete("password")
        |> Map.put(:password_hash, hash_password(password))

      %User{} |> User.changeset(attrs) |> Repo.insert()
    end
  end

  def get_user(id), do: Repo.get(User, id)

  def get_session_user(id, version) when is_integer(version) do
    case get_user(id) do
      %User{status: "active", session_version: ^version} = user -> user
      _ -> nil
    end
  end

  def get_session_user(_id, _version), do: nil

  def get_user_by_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()
    Repo.get_by(User, email: normalized)
  end

  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)
    hash = if user, do: user.password_hash, else: dummy_hash()
    valid? = verify_password(password, hash)

    case user do
      %User{status: "active"} = active_user when valid? ->
        active_user
        |> User.changeset(%{last_signed_in_at: DateTime.utc_now()})
        |> Repo.update()

      _ ->
        {:error, :invalid_credentials}
    end
  end

  def authenticate(_email, _password), do: {:error, :invalid_credentials}

  def change_password(%User{} = user, current_password, new_password) do
    if verify_password(current_password, user.password_hash) do
      reset_password(user, new_password)
    else
      {:error, :invalid_current_password}
    end
  end

  def reset_password(%User{} = user, new_password) do
    with :ok <- validate_password(new_password) do
      user
      |> User.changeset(%{
        password_hash: hash_password(new_password),
        password_changed_at: DateTime.utc_now(),
        session_version: user.session_version + 1
      })
      |> Repo.update()
    end
  end

  def add_workspace_member(%User{} = user, %Workspace{} = workspace, role) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      user_id: user.id,
      workspace_id: workspace.id,
      role: role
    })
    |> Repo.insert()
  end

  def list_research_workspaces(user), do: list_workspaces(user, "viewer")
  def list_operator_workspaces(user), do: list_workspaces(user, "admin")

  def list_workspaces(%User{global_role: "system_admin"}, _minimum_role) do
    Workspace |> order_by([workspace], asc: workspace.name) |> Repo.all()
  end

  def list_workspaces(%User{id: user_id}, minimum_role) do
    allowed_roles = roles_at_or_above(minimum_role)

    Workspace
    |> join(:inner, [workspace], membership in WorkspaceMembership,
      on: membership.workspace_id == workspace.id
    )
    |> where([_workspace, membership], membership.user_id == ^user_id)
    |> where([_workspace, membership], membership.role in ^allowed_roles)
    |> order_by([workspace], asc: workspace.name)
    |> Repo.all()
  end

  def list_workspaces(nil, _minimum_role) do
    if browser_auth_enabled?(),
      do: [],
      else: Workspace |> order_by([w], asc: w.name) |> Repo.all()
  end

  def workspace_authorized?(nil, _workspace_id, _minimum_role),
    do: not browser_auth_enabled?()

  def workspace_authorized?(%User{global_role: "system_admin"}, _workspace_id, _minimum_role),
    do: true

  def workspace_authorized?(%User{id: user_id}, workspace_id, minimum_role) do
    allowed_roles = roles_at_or_above(minimum_role)

    WorkspaceMembership
    |> where(
      [membership],
      membership.user_id == ^user_id and membership.workspace_id == ^normalize_id(workspace_id) and
        membership.role in ^allowed_roles
    )
    |> Repo.exists?()
  end

  def default_research_workspace_id(user) do
    case list_research_workspaces(user) do
      [%Workspace{id: id} | _] -> id
      _ -> nil
    end
  end

  def browser_auth_enabled? do
    Application.get_env(:hydra_agent, :browser_auth, [])
    |> Keyword.get(:enabled?, false)
  end

  def hash_password(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    derived = :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, @derived_bytes)

    Enum.join(
      [
        "pbkdf2-sha256",
        Integer.to_string(@iterations),
        Base.url_encode64(salt, padding: false),
        Base.url_encode64(derived, padding: false)
      ],
      "$"
    )
  end

  def verify_password(password, encoded) when is_binary(password) and is_binary(encoded) do
    with ["pbkdf2-sha256", iterations, encoded_salt, encoded_derived] <-
           String.split(encoded, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.url_decode64(encoded_salt, padding: false),
         {:ok, expected} <- Base.url_decode64(encoded_derived, padding: false) do
      actual = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, byte_size(expected))
      Plug.Crypto.secure_compare(actual, expected)
    else
      _ -> false
    end
  end

  def verify_password(_password, _encoded), do: false

  defp validate_password(password) when is_binary(password) do
    if String.length(password) >= 12,
      do: :ok,
      else: {:error, :password_too_short}
  end

  defp validate_password(_password), do: {:error, :password_required}

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp dummy_hash do
    # Keep invalid-user authentication work comparable without storing a real credential.
    "pbkdf2-sha256$210000$MDAwMDAwMDAwMDAwMDAwMA$HqBdsI5pk8_4YPeQWEwNe0q2i4Cdl72W8geJcIB7xGg"
  end

  defp roles_at_or_above(minimum_role) do
    minimum_rank = Map.fetch!(@role_rank, minimum_role)

    @role_rank
    |> Enum.filter(fn {_role, rank} -> rank >= minimum_rank end)
    |> Enum.map(&elem(&1, 0))
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> -1
    end
  end

  defp normalize_id(_id), do: -1
end
