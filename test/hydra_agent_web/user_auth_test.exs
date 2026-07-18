defmodule HydraAgentWeb.UserAuthTest do
  use HydraAgentWeb.ConnCase, async: false

  import HydraAgent.RuntimeFixtures

  alias HydraAgent.Accounts
  alias HydraAgentWeb.LoginRateLimiter
  alias HydraAgentWeb.UserAuth

  setup do
    original = Application.get_env(:hydra_agent, :browser_auth)
    Application.put_env(:hydra_agent, :browser_auth, enabled?: true)

    on_exit(fn ->
      if original,
        do: Application.put_env(:hydra_agent, :browser_auth, original),
        else: Application.delete_env(:hydra_agent, :browser_auth)
    end)

    :ok
  end

  test "protected browser routes redirect unauthenticated visitors", %{conn: conn} do
    conn = get(conn, "/control")

    assert redirected_to(conn) == "/login"
    assert get_session(conn, :return_to) == "/control"
  end

  test "a valid login renews the session and enters the user's study workspace", %{conn: conn} do
    workspace = workspace_fixture(%{name: "Research", slug: "auth-research"})
    user = user_fixture(%{email: "researcher@example.test"})
    membership_fixture(user, workspace, "researcher")

    conn =
      post(conn, "/login", %{
        "session" => %{
          "email" => "researcher@example.test",
          "password" => "correct horse battery staple"
        }
      })

    assert redirected_to(conn) == "/lab/workspaces/#{workspace.id}/studies"
    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :session_version) == user.session_version
    assert get_session(conn, :live_socket_id) == UserAuth.live_socket_id(user)
  end

  test "the Blueprint Studio flag changes the post-login surface without changing workspace data",
       %{
         conn: conn
       } do
    workspace = workspace_fixture(%{name: "Blueprint", slug: "blueprint-entry"})
    user = user_fixture(%{email: "blueprint-entry@example.test"})
    membership_fixture(user, workspace, "researcher")
    previous = Application.get_env(:hydra_agent, :product_features)

    Application.put_env(:hydra_agent, :product_features,
      surface: :blueprint_studio,
      balanced_mode: true,
      deep_mode: false,
      blueprint_import: true,
      legacy_simlab: true
    )

    on_exit(fn -> Application.put_env(:hydra_agent, :product_features, previous) end)

    login =
      post(conn, "/login", %{
        "session" => %{
          "email" => user.email,
          "password" => "correct horse battery staple"
        }
      })

    assert redirected_to(login) == "/simulations?workspace_id=#{workspace.id}"

    assert HydraAgent.Repo.get!(HydraAgent.Runtime.Workspace, workspace.id).slug ==
             "blueprint-entry"
  end

  test "invalid credentials do not reveal whether an account exists", %{conn: conn} do
    user_fixture(%{email: "known@example.test"})

    known =
      post(conn, "/login", %{
        "session" => %{"email" => "known@example.test", "password" => "wrong-password"}
      })

    unknown =
      build_conn()
      |> post("/login", %{
        "session" => %{"email" => "unknown@example.test", "password" => "wrong-password"}
      })

    assert html_response(known, 422) =~ "Email or password is incorrect."
    assert html_response(unknown, 422) =~ "Email or password is incorrect."
  end

  test "repeated login failures are rate limited without changing the error", %{conn: conn} do
    params = %{
      "session" => %{"email" => "rate-limit@example.test", "password" => "wrong-password"}
    }

    for _attempt <- 1..10 do
      assert conn |> recycle() |> post(~p"/login", params) |> html_response(422) =~
               "Email or password is incorrect."
    end

    limited = conn |> recycle() |> post(~p"/login", params)
    assert html_response(limited, 429) =~ "Email or password is incorrect."
    assert get_resp_header(limited, "retry-after") == ["900"]
  end

  test "varied login identities cannot bypass the source-address limit", %{conn: conn} do
    for attempt <- 1..60 do
      key = LoginRateLimiter.key(conn, "varied-#{attempt}@example.test")
      assert LoginRateLimiter.allowed?(key)
      assert :ok = LoginRateLimiter.record_failure(key)
    end

    refute conn
           |> LoginRateLimiter.key("another-identity@example.test")
           |> LoginRateLimiter.allowed?()
  end

  test "workspace membership prevents cross-tenant reads and writes", %{conn: conn} do
    allowed = workspace_fixture(%{slug: "tenant-allowed"})
    denied = workspace_fixture(%{slug: "tenant-denied"})
    viewer = user_fixture()
    membership_fixture(viewer, allowed, "viewer")
    conn = authenticated_session(conn, viewer)

    assert conn |> get("/lab/workspaces/#{allowed.id}/studies") |> response(200)

    assert conn
           |> recycle()
           |> authenticated_session(viewer)
           |> get("/lab/workspaces/#{denied.id}/studies")
           |> response(404)

    assert conn
           |> recycle()
           |> authenticated_session(viewer)
           |> post("/lab/workspaces/#{allowed.id}/studies", %{
             "study" => %{"question" => "Should not be created"}
           })
           |> response(404)
  end

  test "researchers can mutate only their own workspace", %{conn: conn} do
    allowed = workspace_fixture(%{slug: "researcher-allowed"})
    denied = workspace_fixture(%{slug: "researcher-denied"})
    researcher = user_fixture()
    membership_fixture(researcher, allowed, "researcher")
    conn = authenticated_session(conn, researcher)

    created =
      post(conn, "/lab/workspaces/#{allowed.id}/studies", %{
        "study" => %{"question" => "How will this change affect customers?"}
      })

    assert redirected_to(created) =~ "/lab/workspaces/#{allowed.id}/studies/"

    assert conn
           |> recycle()
           |> authenticated_session(researcher)
           |> post("/lab/workspaces/#{denied.id}/studies", %{
             "study" => %{"question" => "Cross tenant"}
           })
           |> response(404)
  end

  test "system administrators can access every workspace" do
    workspace = workspace_fixture(%{slug: "system-admin-workspace"})
    admin = user_fixture(%{global_role: "system_admin"})

    assert Accounts.workspace_authorized?(admin, workspace.id, "owner")
    assert Enum.any?(Accounts.list_operator_workspaces(admin), &(&1.id == workspace.id))
  end

  test "changing a password revokes existing sessions and renews the current one", %{conn: conn} do
    user = user_fixture(%{email: "security@example.test"})
    old_live_socket_id = UserAuth.live_socket_id(user)
    Phoenix.PubSub.subscribe(HydraAgent.PubSub, old_live_socket_id)

    old_session =
      conn
      |> authenticated_session(user)
      |> put_session(:live_socket_id, old_live_socket_id)

    changed =
      old_session
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put("/account/security", %{
        "security" => %{
          "current_password" => "correct horse battery staple",
          "new_password" => "new correct horse battery staple",
          "new_password_confirmation" => "new correct horse battery staple"
        }
      })

    assert redirected_to(changed) == "/account/security"
    assert get_session(changed, :session_version) == user.session_version + 1
    assert get_session(changed, :live_socket_id) != old_live_socket_id

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^old_live_socket_id,
      event: "disconnect"
    }

    assert old_session
           |> recycle()
           |> authenticated_session(user)
           |> put_session(:session_version, user.session_version)
           |> get("/control")
           |> redirected_to() == "/login"

    assert {:ok, _user} = Accounts.authenticate(user.email, "new correct horse battery staple")
  end

  test "password confirmation prevents an accidental credential change", %{conn: conn} do
    user = user_fixture(%{email: "mismatch@example.test"})

    response =
      conn
      |> authenticated_session(user)
      |> put("/account/security", %{
        "security" => %{
          "current_password" => "correct horse battery staple",
          "new_password" => "a completely new password",
          "new_password_confirmation" => "a different new password"
        }
      })

    assert html_response(response, 422) =~ "New password confirmation does not match."
    assert {:ok, _user} = Accounts.authenticate(user.email, "correct horse battery staple")
  end

  test "account security keeps password confirmation and sign-out reachable", %{conn: conn} do
    user = user_fixture(%{email: "account-nav@example.test"})

    html =
      conn
      |> authenticated_session(user)
      |> get("/account/security")
      |> html_response(200)

    assert html =~ "Account settings for #{user.display_name}"
    assert html =~ "Confirm new password"
    assert html =~ "Current session"
    assert html =~ "runtime-account-link"
    assert html =~ "runtime-signout-button"
  end

  defp authenticated_session(conn, user) do
    init_test_session(conn, user_id: user.id, session_version: user.session_version)
  end
end
