defmodule HydraAgent.Connectors do
  @moduledoc """
  Workspace-scoped external connector accounts and approval-gated actions.

  Connector actions are intentionally durable before they reach an external
  service. Read and draft actions may complete immediately, while external
  writes stay in `awaiting_approval` until an operator approves them.
  """

  import Ecto.Query

  alias HydraAgent.Connectors.{Account, Action}
  alias HydraAgent.Runtime.AgentProfile
  alias HydraAgent.{Knowledge, Plugins, Repo, Secrets}

  @provider_specs [
    %{
      provider: "email",
      label: "Email",
      capabilities: ~w(email.search email.read email.draft email.send),
      required_env: "EMAIL_ACCESS_TOKEN",
      write_actions: ~w(send),
      setup: %{
        credential_env: "EMAIL_ACCESS_TOKEN",
        scopes: ["https://www.googleapis.com/auth/gmail.modify"],
        config_fields: [],
        guide: [
          "Create a Google Cloud OAuth client with Gmail modify scope.",
          "Store the access token in EMAIL_ACCESS_TOKEN.",
          "Keep send actions approval-gated unless the agent is explicitly trusted."
        ],
        config_help: %{}
      }
    },
    %{
      provider: "calendar",
      label: "Calendar",
      capabilities: ~w(calendar.list calendar.propose_event calendar.create_event),
      required_env: "CALENDAR_ACCESS_TOKEN",
      write_actions: ~w(create_event),
      setup: %{
        credential_env: "CALENDAR_ACCESS_TOKEN",
        scopes: ["https://www.googleapis.com/auth/calendar.events"],
        config_fields: ["calendar_id"],
        guide: [
          "Create a Google Cloud OAuth client with Calendar events scope.",
          "Store the access token in CALENDAR_ACCESS_TOKEN.",
          "Set calendar_id to primary or the target shared calendar id."
        ],
        config_help: %{
          "calendar_id" => "Calendar id to read and create events against, usually primary."
        }
      }
    },
    %{
      provider: "notion",
      label: "Notion",
      capabilities: ~w(notion.search notion.create_page notion.append_note),
      required_env: "NOTION_TOKEN",
      write_actions: ~w(create_page append_note),
      setup: %{
        credential_env: "NOTION_TOKEN",
        scopes: ["insert_content"],
        config_fields: ["database_id", "parent_page_id", "page_id"],
        guide: [
          "Create a Notion internal integration and share the target page or database with it.",
          "Store the integration token in NOTION_TOKEN.",
          "Provide at least the target page or database identifiers used by your notes workflow."
        ],
        config_help: %{
          "database_id" => "Optional database id for new research/content pages.",
          "parent_page_id" => "Optional parent page id for new pages.",
          "page_id" => "Optional existing page id for append-note workflows."
        }
      }
    },
    %{
      provider: "notes",
      label: "Notes",
      capabilities: ~w(notes.search notes.append),
      required_env: nil,
      write_actions: ~w(append),
      setup: %{
        credential_env: nil,
        scopes: [],
        config_fields: [],
        guide: [
          "No external secret is required.",
          "Approved append actions create workspace note nodes in Hydra's knowledge graph."
        ],
        config_help: %{}
      }
    },
    %{
      provider: "youtube",
      label: "YouTube Research",
      capabilities: ~w(youtube.search youtube.transcript youtube.metadata),
      required_env: "YOUTUBE_API_KEY",
      write_actions: [],
      setup: %{
        credential_env: "YOUTUBE_API_KEY",
        scopes: ["youtube.readonly"],
        config_fields: ["search_endpoint_url"],
        guide: [
          "Create a YouTube Data API key and store it in YOUTUBE_API_KEY.",
          "Optionally override the search endpoint for a proxy or mock worker.",
          "Use this connector for research and metadata reads, not publishing."
        ],
        config_help: %{
          "search_endpoint_url" => "Optional custom YouTube search endpoint URL."
        }
      }
    },
    %{
      provider: "x",
      label: "X",
      capabilities: ~w(x.draft_post x.publish_post),
      required_env: "X_ACCESS_TOKEN",
      write_actions: ~w(publish_post),
      setup: %{
        credential_env: "X_ACCESS_TOKEN",
        scopes: ["tweet.write", "tweet.read", "users.read", "offline.access"],
        config_fields: [],
        guide: [
          "Create an X app with write permissions.",
          "Store the OAuth access token in X_ACCESS_TOKEN.",
          "Keep publish_post actions approval-required until the posting workflow is proven."
        ],
        config_help: %{}
      }
    },
    %{
      provider: "linkedin",
      label: "LinkedIn",
      capabilities: ~w(linkedin.draft_post linkedin.publish_post),
      required_env: "LINKEDIN_ACCESS_TOKEN",
      write_actions: ~w(publish_post),
      setup: %{
        credential_env: "LINKEDIN_ACCESS_TOKEN",
        scopes: ["w_member_social"],
        config_fields: ["author_urn"],
        guide: [
          "Create a LinkedIn app with w_member_social permission.",
          "Store the member or organization access token in LINKEDIN_ACCESS_TOKEN.",
          "Set author_urn to the person or organization URN that will publish posts."
        ],
        config_help: %{
          "author_urn" =>
            "LinkedIn author URN, for example urn:li:person:... or urn:li:organization:..."
        }
      }
    },
    %{
      provider: "telegram",
      label: "Telegram",
      capabilities: ~w(telegram.draft_message telegram.send_message),
      required_env: "TELEGRAM_BOT_TOKEN",
      write_actions: ~w(send_message),
      setup: %{
        credential_env: "TELEGRAM_BOT_TOKEN",
        scopes: ["bot.sendMessage"],
        config_fields: ["binding_slug", "chat_id"],
        guide: [
          "Create a Telegram bot and store its token in TELEGRAM_BOT_TOKEN.",
          "Use Agent Studio to create a room binding and register the webhook.",
          "Send one message into the chat to capture chat_id when the binding is pending."
        ],
        config_help: %{
          "binding_slug" => "Room channel binding slug used by the webhook URL.",
          "chat_id" =>
            "Telegram chat id; Agent Studio can capture it from the first inbound message."
        }
      }
    }
  ]

  def provider_specs, do: @provider_specs

  def provider_specs(workspace_id) do
    @provider_specs ++
      Enum.map(Plugins.enabled_connector_specs(workspace_id), &plugin_provider_spec/1)
  end

  def provider_setup_guide(provider) do
    spec = provider_spec(provider) || %{setup: %{}}
    provider_setup_guide_from_spec(provider, spec)
  end

  def provider_setup_guide(provider, workspace_id) do
    spec = provider_spec(provider, workspace_id) || %{setup: %{}}
    provider_setup_guide_from_spec(provider, spec)
  end

  defp provider_setup_guide_from_spec(provider, spec) do
    %{
      "provider" => provider,
      "label" => spec[:label] || provider,
      "credential_env" => get_in(spec, [:setup, :credential_env]),
      "scopes" => get_in(spec, [:setup, :scopes]) || [],
      "config_fields" => get_in(spec, [:setup, :config_fields]) || [],
      "config_help" => get_in(spec, [:setup, :config_help]) || %{},
      "steps" => get_in(spec, [:setup, :guide]) || []
    }
  end

  def permission_presets do
    [
      %{
        id: "observe",
        label: "Observe",
        side_effect_classes: ["read_only"],
        requires_approval: false
      },
      %{
        id: "draft",
        label: "Draft",
        side_effect_classes: ["read_only", "network"],
        requires_approval: true
      },
      %{
        id: "approve_writes",
        label: "Approve Writes",
        side_effect_classes: ["read_only", "network", "workspace_write", "external_delivery"],
        requires_approval: true
      },
      %{
        id: "trusted_automation",
        label: "Trusted Automation",
        side_effect_classes: ["read_only", "network", "workspace_write", "external_delivery"],
        requires_approval: true,
        trusted: true
      }
    ]
  end

  def list_accounts(workspace_id, opts \\ []) do
    Account
    |> where([account], account.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:provider, opt(opts, :provider))
    |> maybe_filter(:status, opt(opts, :status))
    |> order_by([account], asc: account.provider, asc: account.display_name)
    |> Repo.all()
  end

  def get_account!(id), do: Repo.get!(Account, id)

  def get_account_for_workspace!(workspace_id, id) do
    Account
    |> where([account], account.workspace_id == ^normalize_id(workspace_id))
    |> Repo.get!(normalize_id(id))
  end

  def create_account(attrs) do
    attrs = stringify_keys(attrs)
    provider = attrs["provider"]
    spec = provider_spec(provider, attrs["workspace_id"])

    attrs =
      case spec && spec[:plugin] do
        nil ->
          attrs

        _plugin ->
          metadata =
            attrs
            |> Map.get("metadata", %{})
            |> Map.merge(%{"plugin_allowed_providers" => [provider]})

          Map.put(attrs, "metadata", metadata)
      end

    attrs =
      attrs
      |> Map.put_new("display_name", (spec && spec.label) || provider || "Connector")
      |> Map.put_new("capabilities", (spec && spec.capabilities) || [])

    %Account{} |> Account.changeset(attrs) |> Repo.insert()
  end

  def setup_readiness(%Account{} = account) do
    spec =
      provider_spec(account.provider, account.workspace_id) ||
        %{
          setup: %{config_fields: [], credential_env: nil}
        }

    credential_env = account.credential_env || get_in(spec, [:setup, :credential_env])
    config_fields = get_in(spec, [:setup, :config_fields]) || []
    missing_required_config = missing_required_config(account)
    missing_config = Enum.filter(config_fields, &blank?(get_in(account.config || %{}, [&1])))
    missing_recommended_config = missing_config -- missing_required_config
    credential = credential_readiness(account, credential_env)

    findings =
      []
      |> maybe_readiness_finding(account.status != "active", "connector_not_active")
      |> maybe_readiness_finding(
        credential["status"] in ["missing_env_ref", "missing_secret_env"],
        credential["status"]
      )
      |> maybe_readiness_finding(
        missing_required_config != [],
        "required_config_missing",
        %{"fields" => missing_required_config}
      )
      |> maybe_readiness_finding(
        missing_recommended_config != [],
        "recommended_config_missing",
        %{"fields" => missing_recommended_config}
      )

    %{
      "status" => readiness_status(findings),
      "provider" => account.provider,
      "credential" => credential,
      "missing_required_config" => missing_required_config,
      "missing_recommended_config" => missing_recommended_config,
      "findings" => findings,
      "setup_guide" => provider_setup_guide(account.provider, account.workspace_id)
    }
  end

  def agent_permission_grants(%Account{} = account) do
    account.metadata
    |> Kernel.||(%{})
    |> Map.get("agent_grants", %{})
  end

  def grant_agent_permission(%Account{} = account, attrs) do
    attrs = stringify_keys(attrs)
    agent_id = normalize_id(attrs["agent_id"])
    action = attrs["action"] || "*"
    mode = attrs["mode"] || "approval_required"

    cond do
      is_nil(agent_id) ->
        {:error, %{"reason" => "agent_id_required"}}

      not connector_agent_in_workspace?(account, agent_id) ->
        {:error, %{"reason" => "connector_agent_not_in_workspace", "agent_id" => agent_id}}

      mode not in ["approval_required", "trusted"] ->
        {:error, %{"reason" => "unsupported_connector_permission_mode", "mode" => mode}}

      not grantable_action?(account.provider, action) ->
        {:error,
         %{
           "reason" => "unsupported_connector_permission_action",
           "provider" => account.provider,
           "action" => action
         }}

      true ->
        metadata = account.metadata || %{}
        grants = Map.get(metadata, "agent_grants", %{})
        key = to_string(agent_id)
        existing = Map.get(grants, key, %{})
        actions = existing |> Map.get("actions", []) |> List.wrap()

        grant =
          existing
          |> Map.merge(%{
            "agent_id" => agent_id,
            "actions" => Enum.uniq(actions ++ [action]),
            "mode" => mode,
            "granted_by" => attrs["granted_by"] || "operator",
            "granted_at" => DateTime.to_iso8601(now())
          })

        account
        |> Account.changeset(%{
          "metadata" => Map.put(metadata, "agent_grants", Map.put(grants, key, grant))
        })
        |> Repo.update()
    end
  end

  def health_check(%Account{} = account) do
    credential_env =
      account.credential_env ||
        get_in(provider_spec(account.provider) || %{}, [:setup, :credential_env])

    result =
      cond do
        account.status != "active" ->
          {:error, %{"reason" => "connector_not_active"}}

        missing_required_config(account) != [] ->
          {:error,
           %{
             "reason" => "missing_required_connector_config",
             "fields" => missing_required_config(account)
           }}

        is_nil(credential_env) or credential_env == "" ->
          {:ok, %{"status" => "healthy", "credential" => "not_required"}}

        true ->
          case Secrets.fetch_env(credential_env) do
            {:ok, _secret} -> {:ok, %{"status" => "healthy", "credential" => "configured"}}
            {:error, error} -> {:error, error}
          end
      end

    persist_health(account, result)
  end

  def list_actions(workspace_id, opts \\ []) do
    Action
    |> where([action], action.workspace_id == ^normalize_id(workspace_id))
    |> maybe_filter(:status, opt(opts, :status))
    |> maybe_filter(:provider, opt(opts, :provider))
    |> order_by([action], desc: action.inserted_at, desc: action.id)
    |> preload([:connector_account, :agent, :automation])
    |> limit(^opt(opts, :limit, 100))
    |> Repo.all()
  end

  def get_action!(id) do
    Action
    |> Repo.get!(id)
    |> Repo.preload([:connector_account, :agent, :automation])
  end

  def get_action_for_workspace!(workspace_id, id) do
    Action
    |> where([action], action.workspace_id == ^normalize_id(workspace_id))
    |> Repo.get!(normalize_id(id))
    |> Repo.preload([:connector_account, :agent, :automation])
  end

  def request_action(%Account{} = account, attrs) do
    attrs = stringify_keys(attrs)
    action_name = attrs["action"]
    side_effect_class = side_effect_class(account.provider, action_name)
    trusted? = trusted_connector_action?(account, attrs, action_name, side_effect_class)

    attrs =
      attrs
      |> Map.put("workspace_id", account.workspace_id)
      |> Map.put("connector_account_id", account.id)
      |> Map.put("provider", account.provider)
      |> Map.put("side_effect_class", side_effect_class)
      |> Map.put_new("input", %{})
      |> Map.put_new("requested_by", "agent")
      |> Map.put("status", initial_status(side_effect_class, trusted?))

    with :ok <- authorize_connector_action(account, attrs, action_name, side_effect_class),
         {:ok, action} <- %Action{} |> Action.changeset(attrs) |> Repo.insert() do
      maybe_execute(action)
    end
  end

  def approve_action(%Action{} = action), do: approve_action(action, %{})

  def approve_action(%Action{status: "awaiting_approval"} = action, attrs) do
    attrs = stringify_keys(attrs)

    action
    |> Action.changeset(%{
      "status" => "approved",
      "approved_by" => attrs["approved_by"] || "operator",
      "approved_at" => now()
    })
    |> Repo.update()
    |> case do
      {:ok, action} -> execute_action(action)
      error -> error
    end
  end

  def approve_action(%Action{} = action, _attrs),
    do: {:error, %{"reason" => "action_not_awaiting_approval", "status" => action.status}}

  def reject_action(%Action{} = action), do: reject_action(action, %{})

  def reject_action(%Action{status: "awaiting_approval"} = action, attrs) do
    attrs = stringify_keys(attrs)

    action
    |> Action.changeset(%{
      "status" => "rejected",
      "approved_by" => attrs["rejected_by"] || attrs["approved_by"] || "operator",
      "approved_at" => now(),
      "last_error" => %{"reason" => "rejected", "detail" => attrs["reason"]}
    })
    |> Repo.update()
  end

  def reject_action(%Action{} = action, _attrs),
    do: {:error, %{"reason" => "action_not_awaiting_approval", "status" => action.status}}

  def execute_action(%Action{} = action) do
    action = Repo.preload(action, [:connector_account])

    case perform_action(action.connector_account, action) do
      {:ok, result} ->
        action
        |> Action.changeset(%{
          "status" => "completed",
          "result" => result,
          "last_error" => %{},
          "executed_at" => now()
        })
        |> Repo.update()

      {:error, error} ->
        action
        |> Action.changeset(%{
          "status" => "failed",
          "last_error" => normalize_error(error),
          "executed_at" => now()
        })
        |> Repo.update()
    end
  end

  defp maybe_execute(%Action{status: "queued"} = action), do: execute_action(action)
  defp maybe_execute(%Action{} = action), do: {:ok, action}

  defp perform_action(%Account{} = account, %Action{} = action) do
    input = action.input || %{}

    cond do
      action.action in ~w(draft draft_post propose_event) ->
        {:ok, %{"mode" => "draft", "provider" => account.provider, "draft" => input}}

      account.provider == "email" and action.action in ~w(search read) ->
        perform_gmail_read(account, action)

      account.provider == "calendar" and action.action in ~w(list_events availability) ->
        perform_calendar_read(account, action)

      account.provider == "youtube" and action.action in ~w(search metadata transcript) ->
        perform_youtube_read(account, action)

      action.side_effect_class == "read_only" ->
        {:ok,
         %{
           "mode" => "read",
           "provider" => account.provider,
           "action" => action.action,
           "input" => input
         }}

      true ->
        perform_external_write(account, action)
    end
  end

  defp perform_gmail_read(%Account{} = account, %Action{action: "search"} = action) do
    with {:ok, token} <- Secrets.fetch_env(account.credential_env) do
      Req.get("https://gmail.googleapis.com/gmail/v1/users/me/messages",
        headers: bearer_headers(token),
        params: %{
          "q" => action.input["query"] || action.input["q"] || "",
          "maxResults" => action.input["max_results"] || 10
        }
      )
      |> response_result("gmail_search")
    else
      {:error, _error} -> read_stub(account, action)
    end
  end

  defp perform_gmail_read(%Account{} = account, %Action{action: "read"} = action) do
    message_id = action.input["message_id"] || action.input["id"]

    with true <- is_binary(message_id) and message_id != "",
         {:ok, token} <- Secrets.fetch_env(account.credential_env) do
      Req.get("https://gmail.googleapis.com/gmail/v1/users/me/messages/#{message_id}",
        headers: bearer_headers(token),
        params: %{"format" => action.input["format"] || "metadata"}
      )
      |> response_result("gmail_read")
    else
      false -> {:error, %{"reason" => "gmail_message_id_required"}}
      {:error, _error} -> read_stub(account, action)
    end
  end

  defp perform_calendar_read(%Account{} = account, %Action{} = action) do
    calendar_id = get_in(account.config || %{}, ["calendar_id"]) || "primary"

    with {:ok, token} <- Secrets.fetch_env(account.credential_env) do
      Req.get(
        "https://www.googleapis.com/calendar/v3/calendars/#{URI.encode_www_form(calendar_id)}/events",
        headers: bearer_headers(token),
        params: %{
          "timeMin" => action.input["time_min"],
          "timeMax" => action.input["time_max"],
          "maxResults" => action.input["max_results"] || 20,
          "singleEvents" => true,
          "orderBy" => "startTime"
        }
      )
      |> response_result("calendar_list_events")
    else
      {:error, _error} -> read_stub(account, action)
    end
  end

  defp perform_youtube_read(%Account{} = account, %Action{} = action) do
    endpoint = get_in(account.config || %{}, ["search_endpoint_url"])

    cond do
      is_binary(endpoint) and endpoint != "" and action.action == "search" ->
        query = get_in(action.input || %{}, ["query"]) || get_in(action.input || %{}, ["q"])

        Req.get(endpoint, params: %{"q" => query})
        |> response_result("youtube_search_endpoint")

      action.action == "search" ->
        with {:ok, api_key} <- Secrets.fetch_env(account.credential_env) do
          Req.get("https://www.googleapis.com/youtube/v3/search",
            params: %{
              "key" => api_key,
              "part" => "snippet",
              "q" => action.input["query"] || action.input["q"] || "",
              "type" => action.input["type"] || "video",
              "maxResults" => action.input["max_results"] || 10
            }
          )
          |> response_result("youtube_search")
        else
          {:error, _error} -> read_stub(account, action, "research_stub")
        end

      action.action == "metadata" ->
        with id when is_binary(id) and id != "" <- action.input["video_id"] || action.input["id"],
             {:ok, api_key} <- Secrets.fetch_env(account.credential_env) do
          Req.get("https://www.googleapis.com/youtube/v3/videos",
            params: %{"key" => api_key, "part" => "snippet,contentDetails,statistics", "id" => id}
          )
          |> response_result("youtube_metadata")
        else
          nil -> {:error, %{"reason" => "youtube_video_id_required"}}
          "" -> {:error, %{"reason" => "youtube_video_id_required"}}
          {:error, _error} -> read_stub(account, action, "research_stub")
        end

      true ->
        read_stub(account, action, "research_stub")
    end
  end

  defp perform_external_write(%Account{} = account, %Action{} = action) do
    endpoint = get_in(account.config || %{}, ["action_endpoint_url"])

    cond do
      account.status != "active" ->
        {:error, %{"reason" => "connector_not_active"}}

      is_binary(endpoint) and endpoint != "" ->
        perform_endpoint_write(account, action, endpoint)

      account.provider == "email" and action.action == "send" ->
        perform_gmail_send(account, action)

      account.provider == "calendar" and action.action == "create_event" ->
        perform_calendar_create_event(account, action)

      account.provider == "notion" and action.action in ~w(create_page append_note) ->
        perform_notion_write(account, action)

      account.provider == "notes" and action.action == "append" ->
        perform_notes_append(account, action)

      account.provider == "x" and action.action == "publish_post" ->
        perform_x_publish_post(account, action)

      account.provider == "linkedin" and action.action == "publish_post" ->
        perform_linkedin_publish_post(account, action)

      true ->
        {:ok,
         %{
           "mode" => "approved_recorded",
           "provider" => account.provider,
           "action" => action.action,
           "delivered" => false,
           "reason" => "no_action_endpoint_configured"
         }}
    end
  end

  defp perform_gmail_send(%Account{} = account, %Action{} = action) do
    with {:ok, token} <- Secrets.fetch_env(account.credential_env),
         {:ok, raw} <- gmail_raw_message(action.input || %{}) do
      Req.post("https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
        headers: bearer_headers(token),
        json: %{"raw" => raw}
      )
      |> response_result("gmail_send")
    else
      {:error, %{"reason" => "missing_secret_env"}} -> approved_recorded(account, action)
      {:error, error} -> {:error, error}
    end
  end

  defp perform_calendar_create_event(%Account{} = account, %Action{} = action) do
    calendar_id = get_in(account.config || %{}, ["calendar_id"]) || "primary"

    with {:ok, token} <- Secrets.fetch_env(account.credential_env),
         event when is_map(event) <- calendar_event_payload(action.input || %{}) do
      Req.post(
        "https://www.googleapis.com/calendar/v3/calendars/#{URI.encode_www_form(calendar_id)}/events",
        headers: bearer_headers(token),
        json: event
      )
      |> response_result("calendar_create_event")
    else
      {:error, %{"reason" => "missing_secret_env"}} -> approved_recorded(account, action)
      {:error, error} -> {:error, error}
    end
  end

  defp perform_notion_write(%Account{} = account, %Action{action: "create_page"} = action) do
    with {:ok, token} <- Secrets.fetch_env(account.credential_env),
         {:ok, payload} <- notion_create_page_payload(account, action.input || %{}) do
      Req.post("https://api.notion.com/v1/pages",
        headers: notion_headers(token),
        json: payload
      )
      |> response_result("notion_create_page")
    else
      {:error, %{"reason" => "missing_secret_env"}} -> approved_recorded(account, action)
      {:error, error} -> {:error, error}
    end
  end

  defp perform_notion_write(%Account{} = account, %Action{action: "append_note"} = action) do
    block_id =
      action.input["page_id"] || action.input["block_id"] ||
        get_in(account.config || %{}, ["page_id"])

    with true <- is_binary(block_id) and block_id != "",
         {:ok, token} <- Secrets.fetch_env(account.credential_env) do
      Req.patch("https://api.notion.com/v1/blocks/#{block_id}/children",
        headers: notion_headers(token),
        json: %{
          "children" => notion_children(action.input["content"] || action.input["text"] || "")
        }
      )
      |> response_result("notion_append_note")
    else
      false -> {:error, %{"reason" => "notion_page_or_block_id_required"}}
      {:error, %{"reason" => "missing_secret_env"}} -> approved_recorded(account, action)
      {:error, error} -> {:error, error}
    end
  end

  defp perform_notes_append(%Account{} = account, %Action{} = action) do
    input = action.input || %{}

    case Knowledge.create_node(%{
           "workspace_id" => account.workspace_id,
           "type_key" => input["type_key"] || "note",
           "title" => input["title"] || "Hydra note",
           "body" => input["content"] || input["text"] || "",
           "attributes" =>
             Map.put(input["attributes"] || %{}, "connector_account_id", account.id),
           "provenance" => %{
             "kind" => "connector_notes_append",
             "connector_action_id" => action.id,
             "provider" => account.provider
           }
         }) do
      {:ok, node} ->
        {:ok,
         %{
           "mode" => "workspace_note",
           "node_id" => node.id,
           "title" => node.title,
           "delivered" => true
         }}

      {:error, changeset} ->
        {:error, %{"reason" => "notes_write_failed", "errors" => changeset_errors(changeset)}}
    end
  end

  defp perform_x_publish_post(%Account{} = account, %Action{} = action) do
    with {:ok, token} <- Secrets.fetch_env(account.credential_env),
         {:ok, payload} <- x_post_payload(action.input || %{}) do
      Req.post("https://api.x.com/2/tweets",
        headers: bearer_headers(token),
        json: payload
      )
      |> response_result("x_publish_post")
    else
      {:error, %{"reason" => "missing_secret_env"}} -> approved_recorded(account, action)
      {:error, error} -> {:error, error}
    end
  end

  defp perform_linkedin_publish_post(%Account{} = account, %Action{} = action) do
    with {:ok, author} <- linkedin_author(account, action.input || %{}),
         {:ok, token} <- Secrets.fetch_env(account.credential_env),
         {:ok, payload} <- linkedin_post_payload(author, action.input || %{}) do
      Req.post("https://api.linkedin.com/rest/posts",
        headers: linkedin_headers(token, account),
        json: payload
      )
      |> response_result("linkedin_publish_post")
    else
      {:error, %{"reason" => "missing_secret_env"}} -> approved_recorded(account, action)
      {:error, error} -> {:error, error}
    end
  end

  defp perform_endpoint_write(%Account{} = account, %Action{} = action, endpoint) do
    headers =
      case Secrets.fetch_env(account.credential_env) do
        {:ok, token} -> [{"authorization", "Bearer #{token}"}]
        {:error, _error} -> []
      end

    Req.post(endpoint,
      headers: headers,
      json: %{
        provider: account.provider,
        action: action.action,
        input: action.input || %{},
        metadata: action.metadata || %{}
      }
    )
    |> case do
      {:ok, response} when response.status in 200..299 ->
        {:ok,
         %{"mode" => "provider_response", "status" => response.status, "body" => response.body}}

      {:ok, response} ->
        {:error,
         %{
           "reason" => "connector_http_error",
           "status" => response.status,
           "body" => response.body
         }}

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  defp response_result({:ok, response}, mode) when response.status in 200..299 do
    {:ok, %{"mode" => mode, "status" => response.status, "body" => response.body}}
  end

  defp response_result({:ok, response}, _mode) do
    {:error,
     %{
       "reason" => "connector_http_error",
       "status" => response.status,
       "body" => response.body
     }}
  end

  defp response_result({:error, error}, _mode), do: {:error, normalize_error(error)}

  defp read_stub(%Account{} = account, %Action{} = action, mode \\ "read") do
    {:ok,
     %{
       "mode" => mode,
       "provider" => account.provider,
       "action" => action.action,
       "configured" => false,
       "input" => action.input || %{}
     }}
  end

  defp approved_recorded(%Account{} = account, %Action{} = action) do
    {:ok,
     %{
       "mode" => "approved_recorded",
       "provider" => account.provider,
       "action" => action.action,
       "delivered" => false,
       "reason" => "credentials_or_endpoint_not_configured"
     }}
  end

  defp bearer_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp linkedin_headers(token, account) do
    bearer_headers(token) ++
      [
        {"linkedin-version", get_in(account.config || %{}, ["linkedin_version"]) || "202602"},
        {"x-restli-protocol-version", "2.0.0"},
        {"content-type", "application/json"}
      ]
  end

  defp notion_headers(token) do
    bearer_headers(token) ++
      [{"notion-version", "2022-06-28"}, {"content-type", "application/json"}]
  end

  defp gmail_raw_message(input) do
    to = input["to"]
    subject = single_line(input["subject"] || "")
    body = input["body"] || input["text"] || ""

    if is_binary(to) and to != "" do
      raw =
        [
          "To: #{single_line(to)}",
          "Subject: #{subject}",
          "Content-Type: text/plain; charset=utf-8",
          "",
          body
        ]
        |> Enum.join("\r\n")
        |> Base.url_encode64(padding: false)

      {:ok, raw}
    else
      {:error, %{"reason" => "email_recipient_required"}}
    end
  end

  defp calendar_event_payload(input) do
    %{
      "summary" => input["summary"] || input["title"] || "Hydra event",
      "description" => input["description"],
      "start" => calendar_time(input["start"] || input["start_at"]),
      "end" => calendar_time(input["end"] || input["end_at"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp calendar_time(nil), do: nil

  defp calendar_time(value) when is_binary(value) do
    if String.contains?(value, "T") do
      %{"dateTime" => value}
    else
      %{"date" => value}
    end
  end

  defp calendar_time(value) when is_map(value), do: value

  defp notion_create_page_payload(account, input) do
    parent_page_id = input["parent_page_id"] || get_in(account.config || %{}, ["parent_page_id"])
    database_id = input["database_id"] || get_in(account.config || %{}, ["database_id"])
    title = input["title"] || "Hydra Note"
    content = input["content"] || input["text"] || ""

    cond do
      is_binary(database_id) and database_id != "" ->
        {:ok,
         %{
           "parent" => %{"database_id" => database_id},
           "properties" => %{"Name" => notion_title_property(title)},
           "children" => notion_children(content)
         }}

      is_binary(parent_page_id) and parent_page_id != "" ->
        {:ok,
         %{
           "parent" => %{"page_id" => parent_page_id},
           "properties" => %{"title" => notion_title_property(title)},
           "children" => notion_children(content)
         }}

      true ->
        {:error, %{"reason" => "notion_parent_required"}}
    end
  end

  defp notion_title_property(title) do
    %{"title" => [%{"text" => %{"content" => to_string(title)}}]}
  end

  defp notion_children(""), do: []

  defp notion_children(content) do
    content
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&chunk_text(&1, 1_900))
    |> Enum.map(fn paragraph ->
      %{
        "object" => "block",
        "type" => "paragraph",
        "paragraph" => %{
          "rich_text" => [%{"type" => "text", "text" => %{"content" => paragraph}}]
        }
      }
    end)
  end

  defp single_line(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
  end

  defp chunk_text("", _size), do: []

  defp chunk_text(text, size) do
    text
    |> to_string()
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  defp x_post_payload(input) do
    text = input["text"] || input["content"] || input["body"]

    cond do
      not is_binary(text) or String.trim(text) == "" ->
        {:error, %{"reason" => "post_text_required"}}

      String.length(text) > 280 ->
        {:error, %{"reason" => "x_post_too_long", "max_length" => 280}}

      true ->
        payload =
          %{"text" => text}
          |> maybe_put("reply", x_reply_payload(input))
          |> maybe_put("quote_tweet_id", input["quote_tweet_id"])
          |> maybe_put("media", x_media_payload(input))

        {:ok, payload}
    end
  end

  defp x_reply_payload(input) do
    case input["in_reply_to_tweet_id"] || input["reply_to_id"] do
      id when is_binary(id) and id != "" -> %{"in_reply_to_tweet_id" => id}
      _id -> nil
    end
  end

  defp x_media_payload(%{"media_ids" => ids}) when is_list(ids) and ids != [] do
    %{"media_ids" => ids}
  end

  defp x_media_payload(_input), do: nil

  defp linkedin_author(account, input) do
    author =
      input["author"] || input["author_urn"] || get_in(account.config || %{}, ["author_urn"])

    if is_binary(author) and String.starts_with?(author, "urn:li:") do
      {:ok, author}
    else
      {:error, %{"reason" => "linkedin_author_urn_required"}}
    end
  end

  defp linkedin_post_payload(author, input) do
    text = input["text"] || input["content"] || input["body"]

    if is_binary(text) and String.trim(text) != "" do
      {:ok,
       %{
         "author" => author,
         "commentary" => text,
         "visibility" => input["visibility"] || "PUBLIC",
         "distribution" => %{
           "feedDistribution" => input["feed_distribution"] || "MAIN_FEED",
           "targetEntities" => [],
           "thirdPartyDistributionChannels" => []
         },
         "lifecycleState" => "PUBLISHED",
         "isReshareDisabledByAuthor" => input["disable_reshares"] in [true, "true", "1", 1]
       }}
    else
      {:error, %{"reason" => "post_text_required"}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp persist_health(account, {:ok, health}) do
    account
    |> Account.changeset(%{
      "last_health" => Map.put(health, "checked_at", DateTime.to_iso8601(now())),
      "last_error" => %{}
    })
    |> Repo.update()
  end

  defp persist_health(account, {:error, error}) do
    account
    |> Account.changeset(%{
      "last_health" => %{"status" => "unhealthy", "checked_at" => DateTime.to_iso8601(now())},
      "last_error" => normalize_error(error)
    })
    |> Repo.update()
  end

  defp initial_status("read_only", _trusted?), do: "queued"
  defp initial_status(_side_effect_class, true), do: "queued"
  defp initial_status(_side_effect_class, _trusted?), do: "awaiting_approval"

  defp side_effect_class(provider, action) when action in [nil, ""],
    do: side_effect_class(provider, "read")

  defp side_effect_class(provider, action) do
    spec = provider_spec(provider)

    cond do
      is_nil(spec) -> "network"
      action in spec.write_actions and provider in ["notion", "notes"] -> "workspace_write"
      action in spec.write_actions -> "external_delivery"
      true -> "read_only"
    end
  end

  defp provider_spec(provider, workspace_id \\ nil)

  defp provider_spec(provider, nil), do: Enum.find(@provider_specs, &(&1.provider == provider))

  defp provider_spec(provider, workspace_id) do
    Enum.find(provider_specs(workspace_id), &(&1.provider == provider))
  end

  defp plugin_provider_spec(spec) do
    spec = stringify_keys(spec)

    %{
      provider: spec["provider"] || spec["name"],
      label: spec["label"] || spec["name"],
      capabilities: spec["capabilities"] || [],
      required_env: spec["required_env"],
      write_actions: spec["write_actions"] || [],
      setup: %{
        credential_env: get_in(spec, ["setup", "credential_env"]) || spec["credential_env"],
        scopes: get_in(spec, ["setup", "scopes"]) || [],
        config_fields: get_in(spec, ["setup", "config_fields"]) || [],
        guide: get_in(spec, ["setup", "guide"]) || [],
        config_help: get_in(spec, ["setup", "config_help"]) || %{}
      },
      plugin: spec["plugin"]
    }
  end

  defp missing_required_config(%Account{} = account) do
    account.provider
    |> provider_spec()
    |> case do
      %{setup: %{config_fields: fields}} ->
        Enum.filter(fields || [], fn field ->
          field in ["author_urn"] and blank?(get_in(account.config || %{}, [field]))
        end)

      _spec ->
        []
    end
  end

  defp authorize_connector_action(_account, _attrs, _action_name, "read_only"), do: :ok

  defp authorize_connector_action(account, attrs, action_name, side_effect_class)
       when side_effect_class in ["workspace_write", "external_delivery"] do
    agent_id = normalize_id(attrs["agent_id"])

    cond do
      is_nil(agent_id) ->
        :ok

      connector_grant?(account, agent_id, action_name) ->
        :ok

      true ->
        {:error,
         %{
           "reason" => "connector_permission_required",
           "provider" => account.provider,
           "action" => action_name,
           "agent_id" => agent_id
         }}
    end
  end

  defp authorize_connector_action(_account, _attrs, _action_name, _side_effect_class), do: :ok

  defp trusted_connector_action?(account, attrs, action_name, side_effect_class)
       when side_effect_class in ["workspace_write", "external_delivery"] do
    agent_id = normalize_id(attrs["agent_id"])
    trusted_requested? = attrs["trusted"] == true or attrs["approval_mode"] == "trusted"

    trusted_requested? and not is_nil(agent_id) and
      connector_grant_mode(account, agent_id, action_name) == "trusted"
  end

  defp trusted_connector_action?(_account, _attrs, _action_name, _side_effect_class), do: false

  defp connector_grant?(account, agent_id, action_name) do
    connector_grant_mode(account, agent_id, action_name) in ["approval_required", "trusted"]
  end

  defp connector_grant_mode(account, agent_id, action_name) do
    grant =
      account
      |> agent_permission_grants()
      |> Map.get(to_string(agent_id))

    actions = grant && List.wrap(grant["actions"])

    cond do
      is_nil(grant) -> nil
      "*" in actions -> grant["mode"] || "approval_required"
      action_name in actions -> grant["mode"] || "approval_required"
      true -> nil
    end
  end

  defp grantable_action?(provider, action) do
    spec = provider_spec(provider)
    action == "*" or (spec && action in spec.write_actions)
  end

  defp connector_agent_in_workspace?(account, agent_id) do
    case Repo.get(AgentProfile, agent_id) do
      %AgentProfile{workspace_id: workspace_id} -> workspace_id == account.workspace_id
      nil -> false
    end
  end

  defp credential_readiness(_account, nil) do
    %{"status" => "not_required", "env" => nil, "ref" => nil}
  end

  defp credential_readiness(%Account{} = account, default_env) do
    env = account.credential_env || default_env

    cond do
      blank?(env) ->
        %{"status" => "missing_env_ref", "env" => nil, "ref" => nil}

      match?({:ok, _secret}, Secrets.fetch_env(env)) ->
        %{"status" => "configured", "env" => env, "ref" => Secrets.safe_ref(env)}

      true ->
        %{"status" => "missing_secret_env", "env" => env, "ref" => Secrets.safe_ref(env)}
    end
  end

  defp maybe_readiness_finding(findings, condition, reason, extra \\ %{})

  defp maybe_readiness_finding(findings, true, reason, extra) do
    [Map.put(extra, "reason", reason) | findings]
  end

  defp maybe_readiness_finding(findings, _condition, _reason, _extra), do: findings

  defp readiness_status(findings) do
    hard_reasons =
      ~w(connector_not_active missing_env_ref missing_secret_env required_config_missing)

    cond do
      Enum.any?(findings, &(&1["reason"] in hard_reasons)) -> "needs_attention"
      findings != [] -> "setup_pending"
      true -> "ready"
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, field, value),
    do: where(query, [record], field(record, ^field) == ^value)

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{"reason" => inspect(error)}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, to_string(key))
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, to_string(key), default)

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp normalize_id(id), do: id

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
