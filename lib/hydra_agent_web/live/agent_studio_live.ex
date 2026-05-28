defmodule HydraAgentWeb.AgentStudioLive do
  use HydraAgentWeb, :live_view

  alias HydraAgent.{
    AgentBuilder,
    AgentPack,
    Automations,
    Budgets,
    Connectors,
    Evals,
    Memory,
    Providers,
    Rooms,
    Runtime
  }

  alias HydraAgentWeb.ControlShell

  @modes [
    {"Sandbox test", "sandbox"},
    {"Memory proposals", "memory_proposals"},
    {"Live durable", "live"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent Studio")
     |> assign(:workspace_id, nil)
     |> assign(:agent_id, nil)
     |> assign(:mode, "sandbox")
     |> assign(:modes, @modes)
     |> assign(:prompt, "")
     |> assign(:studio_result, nil)
     |> assign(:eval_result, nil)
     |> assign(:rooms, [])
     |> assign(:room_id, nil)
     |> assign(:room_filters, [])
     |> assign(:room_messages, [])
     |> assign(:room_deliveries, [])
     |> assign(:builder_presets, AgentBuilder.presets())
     |> assign(:builder_preview, nil)
     |> assign(:builder_result, nil)
     |> assign(:starter_packs, AgentPack.valid_builtin_packs())
     |> assign(:daily_os_setup_result, nil)
     |> load_workspaces()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = selected_workspace_id(socket.assigns.workspaces, params["workspace_id"])
    agent_id = params["agent_id"]
    room_id = params["room_id"]

    {:noreply,
     socket
     |> assign(:workspace_id, workspace_id)
     |> assign(:agent_id, agent_id && parse_id(agent_id))
     |> assign(:room_id, room_id && parse_id(room_id))
     |> assign(:mode, mode_param(params["mode"]))
     |> load_workspace_state()}
  end

  @impl true
  def handle_event("select-agent", params, socket) do
    params = stringify_keys(params)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/control/agents/studio?workspace_id=#{socket.assigns.workspace_id}&agent_id=#{params["agent_id"]}&mode=#{mode_param(params["mode"])}"
     )}
  end

  def handle_event("select-room", %{"room_id" => room_id}, socket) do
    room_id = parse_id(room_id)
    room_filters = socket.assigns.room_filters

    {:noreply,
     socket
     |> assign(:room_id, room_id)
     |> assign(
       :room_messages,
       selected_room_messages(room_id, socket.assigns.rooms, room_filters)
     )
     |> assign(:room_deliveries, selected_room_deliveries(room_id, socket.assigns.rooms))}
  end

  def handle_event("filter-room-messages", %{"room_filter" => params}, socket) do
    filters = room_filters(params)

    {:noreply,
     socket
     |> assign(:room_filters, filters)
     |> assign(
       :room_messages,
       selected_room_messages(socket.assigns.room_id, socket.assigns.rooms, filters)
     )}
  end

  def handle_event("create-room", %{"room" => params}, socket) do
    params = stringify_keys(params)
    title = String.trim(params["title"] || "")
    slug = present(params["slug"]) || slugify(title)
    coordinator_agent_id = optional_id(params["coordinator_agent_id"])

    socket =
      cond do
        title == "" ->
          put_flash(socket, :error, "Room title is required")

        true ->
          case Rooms.create_room(%{
                 workspace_id: socket.assigns.workspace_id,
                 title: title,
                 slug: slug,
                 coordinator_agent_id: coordinator_agent_id
               }) do
            {:ok, room} ->
              socket
              |> put_flash(:info, "Room created")
              |> assign(:room_id, room.id)
              |> load_workspace_state()

            {:error, error} ->
              put_flash(socket, :error, "Room could not be created: #{inspect(error)}")
          end
      end

    {:noreply, socket}
  end

  def handle_event("add-room-member", %{"member" => params}, socket) do
    params = stringify_keys(params)
    room = selected_room(socket)

    socket =
      cond do
        is_nil(room) ->
          put_flash(socket, :error, "Create or select a room first")

        is_nil(optional_id(params["agent_id"])) ->
          put_flash(socket, :error, "Select an agent to add")

        true ->
          case Rooms.create_member(room, %{
                 agent_id: optional_id(params["agent_id"]),
                 mention_handle: params["mention_handle"],
                 role: params["role"] || "participant",
                 response_mode: params["response_mode"] || "on_mention"
               }) do
            {:ok, _member} ->
              socket
              |> put_flash(:info, "Agent added to room")
              |> load_workspace_state()

            {:error, error} ->
              put_flash(socket, :error, "Member could not be added: #{inspect(error)}")
          end
      end

    {:noreply, socket}
  end

  def handle_event("send-room-message", %{"room_message" => params}, socket) do
    params = stringify_keys(params)
    content = String.trim(params["content"] || "")
    room = selected_room(socket)

    socket =
      cond do
        is_nil(room) ->
          put_flash(socket, :error, "Create or select a room first")

        content == "" ->
          put_flash(socket, :error, "Message is required")

        true ->
          case Rooms.send_user_message(room, content, source_channel: "web") do
            {:ok, _result} ->
              socket
              |> assign(
                :room_messages,
                room.id |> Rooms.get_room!() |> Rooms.list_messages(socket.assigns.room_filters)
              )
              |> load_workspace_state()

            {:error, error} ->
              put_flash(socket, :error, "Room message failed: #{inspect(error)}")
          end
      end

    {:noreply, socket}
  end

  def handle_event("create-room-binding", %{"binding" => params}, socket) do
    params = stringify_keys(params)
    room = selected_room(socket)

    socket =
      cond do
        is_nil(room) ->
          put_flash(socket, :error, "Create or select a room first")

        present(params["slug"]) == nil ->
          put_flash(socket, :error, "Binding slug is required")

        true ->
          external_chat_id =
            present(params["external_chat_id"]) || "pending:#{params["slug"]}"

          case Rooms.create_channel_binding(room, %{
                 provider: "telegram",
                 slug: params["slug"],
                 external_chat_id: external_chat_id,
                 token_env: params["token_env"],
                 secret_env: params["secret_env"],
                 config: %{"capture_chat_id" => String.starts_with?(external_chat_id, "pending:")}
               }) do
            {:ok, _binding} ->
              socket
              |> put_flash(:info, "Telegram binding created")
              |> load_workspace_state()

            {:error, error} ->
              put_flash(socket, :error, "Binding could not be created: #{inspect(error)}")
          end
      end

    {:noreply, socket}
  end

  def handle_event("test-room-binding", %{"binding_id" => binding_id}, socket) do
    room = selected_room(socket)

    socket =
      with false <- is_nil(room),
           binding <- Rooms.get_channel_binding_for_room!(room, binding_id),
           {:ok, _response} <- Rooms.send_telegram_message(binding, "Hydra Telegram setup test") do
        put_flash(socket, :info, "Telegram test sent")
      else
        true ->
          put_flash(socket, :error, "Create or select a room first")

        {:error, error} ->
          put_flash(socket, :error, "Telegram test failed: #{inspect(error)}")
      end

    {:noreply, load_workspace_state(socket)}
  end

  def handle_event("retry-room-binding", %{"binding_id" => binding_id}, socket) do
    room = selected_room(socket)

    socket =
      with false <- is_nil(room),
           binding <- Rooms.get_channel_binding_for_room!(room, binding_id),
           {:ok, sent} <- Rooms.retry_channel_binding(binding) do
        socket
        |> put_flash(:info, "Retried #{length(sent)} Telegram messages")
        |> load_workspace_state()
      else
        true ->
          put_flash(socket, :error, "Create or select a room first")

        {:error, error} ->
          put_flash(socket, :error, "Telegram retry failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("retry-room-delivery", %{"delivery_id" => delivery_id}, socket) do
    room = selected_room(socket)

    socket =
      with false <- is_nil(room),
           delivery <- Rooms.get_delivery_for_room!(room, delivery_id),
           {:ok, sent} <- Rooms.retry_delivery(delivery) do
        socket
        |> put_flash(:info, "Retried #{length(sent)} delivery")
        |> load_workspace_state()
      else
        true ->
          put_flash(socket, :error, "Create or select a room first")

        {:error, error} ->
          put_flash(socket, :error, "Delivery retry failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("approve-room-proposal", %{"message_id" => message_id}, socket) do
    room = selected_room(socket)

    socket =
      with false <- is_nil(room),
           {:ok, result} <-
             Rooms.approve_proposal(room, message_id, approved_by: "agent_studio") do
        socket
        |> put_flash(:info, "Approved #{length(result.agent_messages)} agent responses")
        |> load_workspace_state()
      else
        true ->
          put_flash(socket, :error, "Create or select a room first")

        {:error, error} ->
          put_flash(socket, :error, "Proposal approval failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  def handle_event("preview-builder-agent", %{"builder" => params}, socket) do
    preview = AgentBuilder.preview(socket.assigns.workspace_id, params)
    {:noreply, assign(socket, :builder_preview, preview)}
  end

  def handle_event("create-builder-agent", %{"builder" => params}, socket) do
    case AgentBuilder.create(socket.assigns.workspace_id, params) do
      {:ok, %{agent: agent, preview: preview}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent created")
         |> assign(:agent_id, agent.id)
         |> assign(:builder_preview, preview)
         |> assign(:builder_result, preview)
         |> load_workspace_state()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Agent could not be created: #{inspect(error)}")}
    end
  end

  def handle_event("import-starter-pack", %{"slug" => slug}, socket) do
    pack = Enum.find(socket.assigns.starter_packs, &(&1["slug"] == slug))
    workspace_id = socket.assigns.workspace_id

    socket =
      cond do
        is_nil(workspace_id) ->
          put_flash(socket, :error, "Select a workspace first")

        is_nil(pack) ->
          put_flash(socket, :error, "Starter pack not found")

        existing = Runtime.get_agent_by_slug(workspace_id, slug) ->
          socket
          |> put_flash(:info, "#{existing.name} is already imported")
          |> assign(:agent_id, existing.id)

        true ->
          case AgentPack.to_agent_attrs(pack, workspace_id) do
            {:ok, attrs} ->
              case Runtime.create_agent(attrs) do
                {:ok, agent} ->
                  {socket, flash} = maybe_add_starter_pack_to_room(socket, agent, pack)

                  socket
                  |> put_flash(:info, flash || "Imported #{agent.name}")
                  |> assign(:agent_id, agent.id)
                  |> load_workspace_state()

                {:error, error} ->
                  put_flash(
                    socket,
                    :error,
                    "Starter pack could not be imported: #{inspect(error)}"
                  )
              end

            {:error, errors} ->
              put_flash(socket, :error, "Starter pack is invalid: #{inspect(errors)}")
          end
      end

    {:noreply, socket}
  end

  def handle_event("setup-daily-os", _params, socket) do
    socket =
      case setup_daily_os(socket) do
        {:ok, socket, result} ->
          socket
          |> assign(:daily_os_setup_result, result)
          |> assign(:agent_id, result["coordinator_agent_id"])
          |> assign(:room_id, result["room_id"])
          |> put_flash(:info, daily_os_setup_flash(result))
          |> load_workspace_state()

        {:error, message} ->
          put_flash(socket, :error, message)
      end

    {:noreply, socket}
  end

  def handle_event("run-sandbox", %{"studio" => params}, socket) do
    params = stringify_keys(params)
    agent = selected_agent(socket)
    prompt = String.trim(params["prompt"] || "")
    mode = mode_param(params["mode"] || socket.assigns.mode)

    socket =
      cond do
        is_nil(agent) ->
          put_flash(socket, :error, "Select an agent first")

        prompt == "" ->
          put_flash(socket, :error, "Prompt is required")

        true ->
          run_studio_prompt(socket, agent, prompt, mode)
      end

    {:noreply, socket}
  end

  def handle_event("run-eval-suite", %{"suite_id" => suite_id}, socket) do
    agent = selected_agent(socket)

    socket =
      with false <- is_nil(agent),
           suite <- Evals.get_suite!(suite_id),
           {:ok, run} <-
             Evals.create_run(%{
               workspace_id: socket.assigns.workspace_id,
               suite_id: suite.id,
               agent_id: agent.id,
               name: "Agent Studio: #{agent.name}"
             }),
           {:ok, completed_run} <- Evals.execute_run(run) do
        assign(socket, :eval_result, Evals.report(completed_run))
      else
        true -> put_flash(socket, :error, "Select an agent before running evals")
        {:error, error} -> put_flash(socket, :error, "Eval failed: #{inspect(error)}")
      end

    {:noreply, socket}
  end

  defp setup_daily_os(%{assigns: %{workspace_id: nil}}), do: {:error, "Select a workspace first"}

  defp setup_daily_os(socket) do
    workspace_id = socket.assigns.workspace_id
    packs = daily_os_packs(socket.assigns.starter_packs)

    with false <- packs == [],
         {:ok, agent_results} <- ensure_daily_os_agents(workspace_id, packs),
         agents_by_slug <-
           Map.new(agent_results, fn result -> {result.pack["slug"], result.agent} end),
         {:ok, room, room_status} <- ensure_daily_os_room(workspace_id, agents_by_slug),
         {:ok, member_results} <- ensure_daily_os_members(room, agent_results),
         {:ok, binding, binding_status} <- ensure_daily_os_telegram_binding(room),
         {:ok, connector_results} <- ensure_daily_os_connectors(workspace_id, packs),
         {:ok, grant_results, accounts_by_provider} <-
           ensure_daily_os_connector_grants(packs, agents_by_slug, connector_results),
         {:ok, automation_results} <-
           ensure_daily_os_automations(workspace_id, room, agents_by_slug),
         {:ok, budget_results} <- ensure_daily_os_budgets(workspace_id, agents_by_slug) do
      connector_readiness = daily_os_connector_readiness(accounts_by_provider)

      automation_readiness =
        daily_os_automation_readiness(automation_results, accounts_by_provider)

      {:ok, socket,
       %{
         "agents_created" => Enum.count(agent_results, &(&1.status == :created)),
         "agents_reused" => Enum.count(agent_results, &(&1.status == :existing)),
         "members_added" => Enum.count(member_results, &(&1.status == :created)),
         "members_reused" => Enum.count(member_results, &(&1.status == :existing)),
         "automations_created" => Enum.count(automation_results, &(&1.status == :created)),
         "automations_reused" => Enum.count(automation_results, &(&1.status == :existing)),
         "connectors_created" => Enum.count(connector_results, &(&1.status == :created)),
         "connectors_reused" => Enum.count(connector_results, &(&1.status == :existing)),
         "connector_readiness" => connector_readiness,
         "automation_readiness" => automation_readiness,
         "connectors_ready" => Enum.count(connector_readiness, &(&1["status"] == "ready")),
         "connectors_pending" =>
           Enum.count(connector_readiness, &(&1["status"] == "setup_pending")),
         "connectors_needing_attention" =>
           Enum.count(connector_readiness, &(&1["status"] == "needs_attention")),
         "automations_ready" => Enum.count(automation_readiness, &(&1["status"] == "ready")),
         "automations_pending" =>
           Enum.count(automation_readiness, &(&1["status"] == "setup_pending")),
         "automations_blocked" => Enum.count(automation_readiness, &(&1["status"] == "blocked")),
         "budgets_created" => Enum.count(budget_results, &(&1.status == :created)),
         "budgets_reused" => Enum.count(budget_results, &(&1.status == :existing)),
         "grants_created" => Enum.count(grant_results, &(&1.status == :created)),
         "grants_reused" => Enum.count(grant_results, &(&1.status == :existing)),
         "room_id" => room.id,
         "room_title" => room.title,
         "room_status" => room_status,
         "telegram_binding_id" => binding.id,
         "telegram_binding_slug" => binding.slug,
         "telegram_binding_status" => binding_status,
         "coordinator_agent_id" =>
           get_in(agents_by_slug, ["daily-chief-of-staff", Access.key(:id)])
       }}
    else
      true ->
        {:error, "No Daily OS starter packs are available"}

      {:error, error} ->
        {:error, "Daily OS setup failed: #{inspect(error)}"}
    end
  end

  defp daily_os_packs(packs) do
    packs
    |> Enum.filter(&(&1["task_pack"] == "daily_os"))
    |> Enum.sort_by(&daily_os_pack_order(&1["slug"]))
  end

  defp daily_os_pack_order("daily-chief-of-staff"), do: 0
  defp daily_os_pack_order("meeting-prep"), do: 1
  defp daily_os_pack_order("inbox-triage"), do: 2
  defp daily_os_pack_order("research-watch"), do: 3
  defp daily_os_pack_order("content-drafter"), do: 4
  defp daily_os_pack_order(_slug), do: 99

  defp ensure_daily_os_agents(workspace_id, packs) do
    Enum.reduce_while(packs, {:ok, []}, fn pack, {:ok, results} ->
      case ensure_starter_agent(workspace_id, pack) do
        {:ok, agent, status} ->
          {:cont, {:ok, [%{agent: agent, pack: pack, status: status} | results]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp ensure_starter_agent(workspace_id, pack) do
    case Runtime.get_agent_by_slug(workspace_id, pack["slug"]) do
      nil ->
        with {:ok, attrs} <- AgentPack.to_agent_attrs(pack, workspace_id),
             {:ok, agent} <- Runtime.create_agent(attrs) do
          {:ok, agent, :created}
        end

      agent ->
        {:ok, agent, :existing}
    end
  end

  defp ensure_daily_os_room(workspace_id, agents_by_slug) do
    coordinator = agents_by_slug["daily-chief-of-staff"]

    case Enum.find(Rooms.list_rooms(workspace_id), &(&1.slug == "daily-os")) do
      nil ->
        with {:ok, room} <-
               Rooms.create_room(%{
                 workspace_id: workspace_id,
                 title: "Daily OS",
                 slug: "daily-os",
                 coordinator_agent_id: coordinator && coordinator.id,
                 metadata: %{"setup_wizard" => "daily_os"}
               }) do
          {:ok, room, :created}
        end

      room ->
        if coordinator && is_nil(room.coordinator_agent_id) do
          with {:ok, room} <- Rooms.update_room(room, %{coordinator_agent_id: coordinator.id}) do
            {:ok, room, :existing}
          end
        else
          {:ok, room, :existing}
        end
    end
  end

  defp ensure_daily_os_members(room, agent_results) do
    room = Rooms.get_room!(room.id)

    Enum.reduce_while(agent_results, {:ok, []}, fn %{agent: agent, pack: pack}, {:ok, results} ->
      case ensure_daily_os_member(room, agent, pack) do
        {:ok, member, status} ->
          {:cont, {:ok, [%{member: member, status: status} | results]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp ensure_daily_os_member(room, agent, pack) do
    room = Rooms.get_room!(room.id)

    case Enum.find(room.members || [], &(&1.agent_id == agent.id)) do
      nil ->
        defaults = pack["room_defaults"] || %{}
        desired_handle = defaults["mention_handle"] || agent.slug

        Rooms.create_member(room, %{
          agent_id: agent.id,
          mention_handle: available_room_handle(room, desired_handle, agent),
          role:
            defaults["role"] ||
              if(defaults["coordinator"], do: "coordinator", else: "participant"),
          response_mode: defaults["response_mode"] || "on_mention",
          metadata: %{"starter_pack_slug" => pack["slug"], "task_pack" => pack["task_pack"]}
        })
        |> case do
          {:ok, member} -> {:ok, member, :created}
          error -> error
        end

      member ->
        {:ok, member, :existing}
    end
  end

  defp available_room_handle(room, desired_handle, agent) do
    desired_handle = slugify(to_string(desired_handle || agent.slug))
    taken_handles = MapSet.new(Enum.map(room.members || [], & &1.mention_handle))

    if MapSet.member?(taken_handles, desired_handle) do
      "#{desired_handle}-#{agent.id}"
    else
      desired_handle
    end
  end

  defp ensure_daily_os_telegram_binding(room) do
    room = Rooms.get_room!(room.id)
    slug = "daily-os-telegram-#{room.workspace_id}"

    case Enum.find(room.channel_bindings || [], &(&1.provider == "telegram" and &1.slug == slug)) do
      nil ->
        Rooms.create_channel_binding(room, %{
          provider: "telegram",
          slug: slug,
          external_chat_id: "pending:#{slug}",
          token_env: "TELEGRAM_BOT_TOKEN",
          secret_env: "TELEGRAM_WEBHOOK_SECRET",
          config: %{"capture_chat_id" => true},
          metadata: %{"setup_wizard" => "daily_os"}
        })
        |> case do
          {:ok, binding} -> {:ok, binding, :created}
          error -> error
        end

      binding ->
        {:ok, binding, :existing}
    end
  end

  defp ensure_daily_os_connectors(workspace_id, packs) do
    providers =
      packs
      |> Enum.flat_map(&(&1["connector_requirements"] || []))
      |> Enum.uniq()
      |> Enum.sort()

    existing_by_slug =
      workspace_id
      |> Connectors.list_accounts()
      |> Map.new(&{&1.slug, &1})

    specs_by_provider = Map.new(Connectors.provider_specs(), &{&1.provider, &1})

    Enum.reduce_while(providers, {:ok, []}, fn provider, {:ok, results} ->
      slug = "#{provider}-daily-os"
      spec = specs_by_provider[provider]

      cond do
        is_nil(spec) ->
          {:halt, {:error, %{"reason" => "missing_connector_provider", "provider" => provider}}}

        existing = existing_by_slug[slug] ->
          {:cont, {:ok, [%{account: existing, status: :existing} | results]}}

        true ->
          case Connectors.create_account(%{
                 workspace_id: workspace_id,
                 provider: provider,
                 slug: slug,
                 display_name: "#{spec.label} Daily OS",
                 credential_env: get_in(spec, [:setup, :credential_env]),
                 config: %{},
                 metadata: %{"setup_wizard" => "daily_os"}
               }) do
            {:ok, account} ->
              {:cont, {:ok, [%{account: account, status: :created} | results]}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp ensure_daily_os_connector_grants(packs, agents_by_slug, connector_results) do
    accounts_by_provider = Map.new(connector_results, &{&1.account.provider, &1.account})
    specs_by_provider = Map.new(Connectors.provider_specs(), &{&1.provider, &1})

    packs
    |> Enum.flat_map(fn pack ->
      agent = agents_by_slug[pack["slug"]]

      pack
      |> Map.get("connector_requirements", [])
      |> Enum.flat_map(fn provider ->
        write_actions =
          specs_by_provider
          |> Map.get(provider)
          |> case do
            %{write_actions: actions} -> actions
            _spec -> []
          end

        Enum.map(write_actions, fn action ->
          %{agent: agent, provider: provider, action: action}
        end)
      end)
    end)
    |> Enum.reject(&is_nil(&1.agent))
    |> Enum.reduce_while({:ok, [], accounts_by_provider}, fn grant,
                                                             {:ok, results, accounts_by_provider} ->
      account = accounts_by_provider[grant.provider]

      cond do
        is_nil(account) ->
          {:halt,
           {:error, %{"reason" => "missing_connector_account", "provider" => grant.provider}}}

        connector_grant_exists?(account, grant.agent.id, grant.action) ->
          {:cont,
           {:ok,
            [
              %{account: account, agent: grant.agent, action: grant.action, status: :existing}
              | results
            ], accounts_by_provider}}

        true ->
          case Connectors.grant_agent_permission(account, %{
                 "agent_id" => grant.agent.id,
                 "action" => grant.action,
                 "mode" => "approval_required",
                 "granted_by" => "daily_os_setup"
               }) do
            {:ok, account} ->
              accounts_by_provider = Map.put(accounts_by_provider, account.provider, account)

              {:cont,
               {:ok,
                [
                  %{account: account, agent: grant.agent, action: grant.action, status: :created}
                  | results
                ], accounts_by_provider}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, results, accounts_by_provider} ->
        {:ok, Enum.reverse(results), accounts_by_provider}

      error ->
        error
    end
  end

  defp connector_grant_exists?(account, agent_id, action) do
    grant =
      account
      |> Connectors.agent_permission_grants()
      |> Map.get(to_string(agent_id))

    actions = grant && List.wrap(grant["actions"])
    not is_nil(grant) and ("*" in actions or action in actions)
  end

  defp daily_os_connector_readiness(accounts_by_provider) do
    accounts_by_provider
    |> Map.values()
    |> Enum.map(fn account ->
      readiness = Connectors.setup_readiness(account)

      %{
        "provider" => account.provider,
        "display_name" => account.display_name,
        "status" => readiness["status"],
        "credential" => readiness["credential"],
        "missing_required_config" => readiness["missing_required_config"],
        "missing_recommended_config" => readiness["missing_recommended_config"],
        "findings" => readiness["findings"],
        "setup_guide" => readiness["setup_guide"],
        "grant_count" => account |> Connectors.agent_permission_grants() |> map_size()
      }
    end)
    |> Enum.sort_by(& &1["provider"])
  end

  defp daily_os_automation_readiness(automation_results, accounts_by_provider) do
    connector_accounts = Map.values(accounts_by_provider)

    automation_results
    |> Enum.map(fn %{automation: automation} ->
      readiness = Automations.readiness(automation, connector_accounts)

      %{
        "automation_id" => automation.id,
        "name" => automation.name,
        "slug" => automation.slug,
        "recipe_id" => get_in(automation.metadata || %{}, ["recipe_id"]),
        "status" => readiness["status"],
        "required_connectors" => readiness["required_connectors"],
        "blockers" => readiness["blockers"],
        "warnings" => readiness["warnings"]
      }
    end)
    |> Enum.sort_by(& &1["slug"])
  end

  defp ensure_daily_os_automations(workspace_id, room, agents_by_slug) do
    recipe_agent_slugs = %{
      "daily_briefing" => "daily-chief-of-staff",
      "meeting_prep" => "meeting-prep",
      "post_meeting_follow_up" => "meeting-prep",
      "inbox_triage" => "inbox-triage",
      "follow_up_reminders" => "inbox-triage",
      "research_watch" => "research-watch",
      "weekly_research_digest" => "research-watch",
      "content_draft" => "content-drafter",
      "weekly_content_pipeline" => "content-drafter",
      "reminders" => "daily-chief-of-staff"
    }

    existing_by_slug =
      workspace_id
      |> Automations.list_automations()
      |> Map.new(&{&1.slug, &1})

    recipes_by_id = Map.new(Automations.recipes(), &{&1["id"], &1})

    recipe_agent_slugs
    |> Enum.sort_by(fn {recipe_id, _agent_slug} -> recipe_id end)
    |> Enum.reduce_while({:ok, []}, fn {recipe_id, agent_slug}, {:ok, results} ->
      recipe = recipes_by_id[recipe_id]
      agent = agents_by_slug[agent_slug]

      cond do
        is_nil(recipe) ->
          {:halt, {:error, %{"reason" => "missing_recipe", "recipe_id" => recipe_id}}}

        is_nil(agent) ->
          {:halt, {:error, %{"reason" => "missing_agent", "agent_slug" => agent_slug}}}

        existing = existing_by_slug[recipe["slug"]] ->
          {:cont, {:ok, [%{automation: existing, status: :existing} | results]}}

        true ->
          case Automations.create_from_recipe(workspace_id, recipe_id, %{
                 "agent_id" => agent.id,
                 "room_id" => room.id,
                 "delivery_target" => "room",
                 "metadata" => %{
                   "setup_wizard" => "daily_os",
                   "agent_slug" => agent_slug
                 }
               }) do
            {:ok, automation} ->
              {:cont, {:ok, [%{automation: automation, status: :created} | results]}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp ensure_daily_os_budgets(workspace_id, agents_by_slug) do
    existing_by_key =
      workspace_id
      |> Budgets.list_budgets()
      |> Enum.reject(&(is_nil(&1.metadata) or is_nil(&1.metadata["budget_key"])))
      |> Map.new(fn budget -> {budget.metadata["budget_key"], budget} end)

    budget_specs =
      [
        %{
          key: "daily-os-workspace-monthly",
          name: "Daily OS Workspace Monthly Token Limit",
          period: "monthly",
          token_limit: 1_000_000,
          agent: nil
        }
      ] ++
        Enum.map(agents_by_slug, fn {slug, agent} ->
          %{
            key: "daily-os-agent-#{slug}-daily",
            name: "#{agent.name} Daily Token Limit",
            period: "daily",
            token_limit: 100_000,
            agent: agent
          }
        end)

    budget_specs
    |> Enum.sort_by(& &1.key)
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, results} ->
      case existing_by_key[spec.key] do
        nil ->
          case Budgets.create_budget(%{
                 workspace_id: workspace_id,
                 agent_id: spec.agent && spec.agent.id,
                 name: spec.name,
                 period: spec.period,
                 token_limit: spec.token_limit,
                 metadata: %{
                   "setup_wizard" => "daily_os",
                   "budget_key" => spec.key,
                   "permission_preset" => "approve_writes"
                 }
               }) do
            {:ok, budget} ->
              {:cont, {:ok, [%{budget: budget, status: :created} | results]}}

            {:error, error} ->
              {:halt, {:error, error}}
          end

        budget ->
          {:cont, {:ok, [%{budget: budget, status: :existing} | results]}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp daily_os_setup_flash(result) do
    "Daily OS ready: #{result["agents_created"]} agents imported, #{result["members_added"]} room members added, #{result["connectors_created"]} connectors prepared, #{result["grants_created"]} grants created, #{result["automations_created"]} automations scheduled, #{result["budgets_created"]} budgets created."
  end

  defp maybe_add_starter_pack_to_room(socket, agent, pack) do
    room = selected_room(socket)
    defaults = pack["room_defaults"] || %{}

    cond do
      is_nil(room) or defaults == %{} ->
        {socket, nil}

      Enum.any?(room.members || [], &(&1.agent_id == agent.id)) ->
        {socket, "Imported #{agent.name}"}

      true ->
        attrs = %{
          agent_id: agent.id,
          mention_handle: defaults["mention_handle"] || agent.slug,
          role:
            defaults["role"] ||
              if(defaults["coordinator"], do: "coordinator", else: "participant"),
          response_mode: defaults["response_mode"] || "on_mention",
          metadata: %{"starter_pack_slug" => pack["slug"], "task_pack" => pack["task_pack"]}
        }

        case Rooms.create_member(room, attrs) do
          {:ok, _member} -> {socket, "Imported #{agent.name} and added it to #{room.title}"}
          {:error, _error} -> {socket, "Imported #{agent.name}"}
        end
    end
  end

  defp run_studio_prompt(socket, agent, prompt, mode) do
    memory = Memory.recall(agent, prompt, limit: 6)

    request = %{
      "messages" => [
        %{"role" => "system", "content" => agent.system_prompt || ""},
        %{"role" => "user", "content" => prompt}
      ],
      "metadata" => %{"memory" => memory}
    }

    case Providers.chat(agent, request) do
      {:ok, response} ->
        proposal =
          if mode == "memory_proposals" do
            {:ok, proposal} =
              Memory.propose_node(agent, %{
                title: "Agent Studio: #{String.slice(prompt, 0, 48)}",
                body: get_in(response, ["message", "content"]) || "",
                reason: "Agent Studio memory proposal",
                evidence: [%{"prompt" => prompt}]
              })

            proposal
          end

        assign(socket,
          mode: mode,
          prompt: prompt,
          studio_result: %{
            "mode" => mode,
            "durable_writes" => mode in ["memory_proposals", "live"],
            "memory" => memory,
            "provider_response" => response,
            "proposal_id" => proposal && proposal.id
          }
        )

      {:error, error} ->
        put_flash(socket, :error, "Studio run failed: #{inspect(error)}")
    end
  end

  defp load_workspaces(socket), do: assign(socket, :workspaces, Runtime.list_workspaces())

  defp load_workspace_state(%{assigns: %{workspace_id: nil}} = socket) do
    socket
    |> assign(:agents, [])
    |> assign(:eval_suites, [])
    |> assign(:rooms, [])
    |> assign(:room_id, nil)
    |> assign(:room_messages, [])
    |> assign(:room_deliveries, [])
  end

  defp load_workspace_state(%{assigns: %{workspace_id: workspace_id}} = socket) do
    agents = Runtime.list_agents(workspace_id)
    agent_id = socket.assigns.agent_id || (List.first(agents) && List.first(agents).id)
    rooms = Rooms.list_rooms(workspace_id)
    room_id = room_id(socket.assigns.room_id, rooms)

    socket
    |> assign(:agents, agents)
    |> assign(:agent_id, agent_id)
    |> assign(:rooms, rooms)
    |> assign(:room_id, room_id)
    |> assign(:room_messages, selected_room_messages(room_id, rooms, socket.assigns.room_filters))
    |> assign(:room_deliveries, selected_room_deliveries(room_id, rooms))
    |> assign(:eval_suites, Evals.list_suites(workspace_id))
  end

  defp selected_agent(socket) do
    Enum.find(socket.assigns.agents, &(&1.id == socket.assigns.agent_id))
  end

  defp selected_room(%{assigns: assigns}), do: selected_room(assigns)

  defp selected_room(%{rooms: rooms, room_id: room_id}) do
    Enum.find(rooms, &(&1.id == room_id))
  end

  defp selected_room_messages(nil, _rooms, _filters), do: []

  defp selected_room_messages(room_id, rooms, filters) do
    case Enum.find(rooms, &(&1.id == room_id)) do
      nil -> []
      room -> Rooms.list_messages(room, filters)
    end
  end

  defp selected_room_deliveries(nil, _rooms), do: []

  defp selected_room_deliveries(room_id, rooms) do
    case Enum.find(rooms, &(&1.id == room_id)) do
      nil -> []
      room -> Rooms.list_deliveries(room, limit: 20)
    end
  end

  defp room_filters(params) do
    params = stringify_keys(params || %{})

    [
      query: present(params["query"]),
      author_type: present(params["author_type"]),
      source_channel: present(params["source_channel"]),
      delivery_status: present(params["delivery_status"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp filter_value(filters, key) when is_list(filters), do: Keyword.get(filters, key, "")

  defp filter_value(filters, key) when is_map(filters),
    do: Map.get(filters, key) || Map.get(filters, to_string(key), "")

  defp telegram_setup_readiness(binding), do: Rooms.telegram_setup_readiness(binding)
  defp telegram_setup_items(binding), do: telegram_setup_readiness(binding)["items"]
  defp telegram_setup_status(binding), do: telegram_setup_readiness(binding)["status"]

  defp telegram_setup_status_class("ready"), do: "text-emerald-700"
  defp telegram_setup_status_class("setup_pending"), do: "text-amber-700"
  defp telegram_setup_status_class(_status), do: "text-red-700"

  defp telegram_setup_status_label("setup_pending"), do: "setup pending"
  defp telegram_setup_status_label("needs_attention"), do: "needs attention"
  defp telegram_setup_status_label(status), do: status

  defp telegram_setup_item_class("ok"), do: "border-emerald-200 bg-emerald-50 text-emerald-800"
  defp telegram_setup_item_class("warning"), do: "border-amber-200 bg-amber-50 text-amber-800"
  defp telegram_setup_item_class("error"), do: "border-red-200 bg-red-50 text-red-800"

  defp daily_os_readiness_class("ready"), do: "text-emerald-700"
  defp daily_os_readiness_class("setup_pending"), do: "text-amber-700"
  defp daily_os_readiness_class(_status), do: "text-red-700"

  defp daily_os_finding_text(%{"reason" => reason, "fields" => fields}) when is_list(fields) do
    "#{reason}: #{Enum.join(fields, ", ")}"
  end

  defp daily_os_finding_text(%{"reason" => reason}), do: reason
  defp daily_os_finding_text(finding), do: inspect(finding)

  defp daily_os_readiness_issues(readiness) do
    (readiness["blockers"] || []) ++ (readiness["warnings"] || [])
  end

  defp daily_os_readiness_issue_class(%{"severity" => "warning"}), do: "text-amber-700"
  defp daily_os_readiness_issue_class(_issue), do: "text-red-700"

  defp daily_os_readiness_issue_text(%{"provider" => provider, "reason" => "connector_missing"}) do
    "#{provider}: connector account is missing"
  end

  defp daily_os_readiness_issue_text(%{"provider" => provider, "findings" => findings})
       when is_list(findings) and findings != [] do
    "#{provider}: #{Enum.map_join(findings, "; ", &daily_os_finding_text/1)}"
  end

  defp daily_os_readiness_issue_text(%{"provider" => provider, "reason" => reason}) do
    "#{provider}: #{reason}"
  end

  defp daily_os_readiness_issue_text(issue), do: inspect(issue)

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")

  defp telegram_capture_pending?(binding) do
    String.starts_with?(to_string(binding.external_chat_id || ""), "pending:") and
      get_in(binding.config || %{}, ["capture_chat_id"]) == true
  end

  defp delivery_status_class("sent"), do: "text-emerald-700"
  defp delivery_status_class("delivered"), do: "text-emerald-700"
  defp delivery_status_class("failed"), do: "text-red-700"
  defp delivery_status_class("pending"), do: "text-amber-700"
  defp delivery_status_class(_status), do: "text-zinc-600"

  defp room_id(nil, []), do: nil
  defp room_id(nil, [room | _rooms]), do: room.id

  defp room_id(room_id, rooms) do
    if Enum.any?(rooms, &(&1.id == room_id)), do: room_id, else: room_id(nil, rooms)
  end

  defp selected_workspace_id([], _param), do: nil
  defp selected_workspace_id([workspace | _workspaces], nil), do: workspace.id

  defp selected_workspace_id(workspaces, workspace_id) do
    parsed_id = parse_id(workspace_id)

    if Enum.any?(workspaces, &(&1.id == parsed_id)) do
      parsed_id
    else
      selected_workspace_id(workspaces, nil)
    end
  end

  defp mode_param(mode) when mode in ["sandbox", "memory_proposals", "live"], do: mode
  defp mode_param(_mode), do: "sandbox"

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp optional_id(nil), do: nil
  defp optional_id(""), do: nil
  defp optional_id(id), do: parse_id(id)

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(_value), do: nil

  defp slugify(""), do: "room-#{System.unique_integer([:positive])}"

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> slugify("")
      slug -> slug
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="agent-studio" class="space-y-8">
      <ControlShell.header
        active={:agents}
        description="Prototype one agent with explicit sandbox, memory-proposal, or live durable modes."
        eyebrow="Agent Studio"
        title="Agent Studio"
        workspaces={@workspaces}
        workspace_id={@workspace_id}
      />

      <%= if @workspace_id do %>
        <section
          id="daily-os-setup"
          class="rounded-lg border border-zinc-200 bg-white p-4"
        >
          <div class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
            <div>
              <h2 class="text-base font-semibold text-zinc-950">Daily OS Setup</h2>
              <p class="mt-1 text-sm text-zinc-500">
                Create the agent room, starter roster, Telegram binding, and core automations.
              </p>
            </div>
            <button
              type="button"
              phx-click="setup-daily-os"
              class="rounded-md bg-zinc-950 px-3 py-2 text-sm font-semibold text-white"
            >
              Set Up Daily OS
            </button>
          </div>
          <div
            :if={@daily_os_setup_result}
            id="daily-os-setup-result"
            class="mt-4 grid gap-2 text-xs text-zinc-600 md:grid-cols-3 xl:grid-cols-7"
          >
            <div class="rounded-md border border-zinc-200 p-2">
              <p class="font-semibold text-zinc-950">Room</p>
              <p>{@daily_os_setup_result["room_title"]}</p>
              <p>{@daily_os_setup_result["room_status"]}</p>
            </div>
            <div class="rounded-md border border-zinc-200 p-2">
              <p class="font-semibold text-zinc-950">Agents</p>
              <p>{@daily_os_setup_result["agents_created"]} imported</p>
              <p>{@daily_os_setup_result["agents_reused"]} reused</p>
            </div>
            <div class="rounded-md border border-zinc-200 p-2">
              <p class="font-semibold text-zinc-950">Room Members</p>
              <p>{@daily_os_setup_result["members_added"]} added</p>
              <p>{@daily_os_setup_result["members_reused"]} reused</p>
            </div>
            <div class="rounded-md border border-zinc-200 p-2">
              <p class="font-semibold text-zinc-950">Connectors</p>
              <p>{@daily_os_setup_result["connectors_created"]} prepared</p>
              <p>{@daily_os_setup_result["connectors_reused"]} reused</p>
              <p>{@daily_os_setup_result["connectors_ready"]} ready</p>
              <p>{@daily_os_setup_result["connectors_needing_attention"]} need setup</p>
            </div>
            <div class="rounded-md border border-zinc-200 p-2">
              <p class="font-semibold text-zinc-950">Grants</p>
              <p>{@daily_os_setup_result["grants_created"]} created</p>
              <p>{@daily_os_setup_result["grants_reused"]} reused</p>
            </div>
            <div class="rounded-md border border-zinc-200 p-2">
              <p class="font-semibold text-zinc-950">Automations</p>
              <p>{@daily_os_setup_result["automations_created"]} scheduled</p>
              <p>{@daily_os_setup_result["automations_reused"]} reused</p>
              <p>{@daily_os_setup_result["automations_ready"]} ready</p>
              <p>{@daily_os_setup_result["automations_blocked"]} blocked</p>
            </div>
            <div class="rounded-md border border-zinc-200 p-2">
              <p class="font-semibold text-zinc-950">Budgets</p>
              <p>{@daily_os_setup_result["budgets_created"]} created</p>
              <p>{@daily_os_setup_result["budgets_reused"]} reused</p>
            </div>
          </div>
          <div
            :if={@daily_os_setup_result}
            id="daily-os-connector-readiness"
            class="mt-4 grid gap-2 md:grid-cols-2 xl:grid-cols-4"
          >
            <div
              :for={connector <- @daily_os_setup_result["connector_readiness"]}
              id={"daily-os-connector-readiness-#{connector["provider"]}"}
              class="rounded-md border border-zinc-200 p-3 text-xs"
            >
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <p class="truncate font-semibold text-zinc-950">{connector["display_name"]}</p>
                  <p class="mt-1 text-zinc-500">{connector["provider"]}</p>
                </div>
                <p class={["font-semibold", daily_os_readiness_class(connector["status"])]}>
                  {connector["status"]}
                </p>
              </div>
              <p class="mt-2 text-zinc-500">
                credential {get_in(connector, ["credential", "ref"]) || "none"}
              </p>
              <p class="mt-1 text-zinc-500">agent grants {connector["grant_count"]}</p>
              <p
                :for={step <- get_in(connector, ["setup_guide", "steps"]) || []}
                class="mt-1 text-zinc-600"
              >
                {step}
              </p>
              <p
                :for={
                  field <-
                    (connector["missing_required_config"] || []) ++
                      (connector["missing_recommended_config"] || [])
                }
                class="mt-1 font-medium text-amber-700"
              >
                {field}: {get_in(connector, ["setup_guide", "config_help", field]) ||
                  "configure this field"}
              </p>
              <p
                :for={finding <- connector["findings"]}
                class="mt-1 font-medium text-amber-700"
              >
                {daily_os_finding_text(finding)}
              </p>
            </div>
          </div>
          <div
            :if={@daily_os_setup_result}
            id="daily-os-automation-readiness"
            class="mt-4 grid gap-2 md:grid-cols-2 xl:grid-cols-3"
          >
            <div
              :for={automation <- @daily_os_setup_result["automation_readiness"]}
              id={"daily-os-automation-readiness-#{automation["slug"]}"}
              class="rounded-md border border-zinc-200 p-3 text-xs"
            >
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <p class="truncate font-semibold text-zinc-950">{automation["name"]}</p>
                  <p class="mt-1 text-zinc-500">
                    {join_or_none(automation["required_connectors"])}
                  </p>
                </div>
                <p class={["font-semibold", daily_os_readiness_class(automation["status"])]}>
                  {automation["status"]}
                </p>
              </div>
              <p
                :for={issue <- daily_os_readiness_issues(automation)}
                class={["mt-1 font-medium", daily_os_readiness_issue_class(issue)]}
              >
                {daily_os_readiness_issue_text(issue)}
              </p>
            </div>
          </div>
        </section>

        <section class="grid gap-6 xl:grid-cols-[260px_1fr_360px]">
          <aside class="rounded-lg border border-zinc-200 bg-white p-4">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold text-zinc-950">Rooms</h2>
              <span class="rounded-md bg-zinc-100 px-2 py-1 text-xs font-medium text-zinc-600">
                {length(@rooms)}
              </span>
            </div>
            <div id="agent-studio-room-list" class="mt-4 space-y-2">
              <button
                :for={room <- @rooms}
                type="button"
                phx-click="select-room"
                phx-value-room_id={room.id}
                class={[
                  "block w-full rounded-md border px-3 py-2 text-left text-sm",
                  room.id == @room_id &&
                    "border-zinc-950 bg-zinc-950 text-white",
                  room.id != @room_id &&
                    "border-zinc-200 text-zinc-700 hover:border-zinc-300"
                ]}
              >
                <span class="block truncate font-medium">{room.title}</span>
                <span class="block truncate text-xs opacity-70">/{room.slug}</span>
              </button>
              <p :if={@rooms == []} class="text-sm text-zinc-500">
                No rooms yet.
              </p>
            </div>

            <.form for={%{}} as={:room} phx-submit="create-room" class="mt-5 space-y-3">
              <input
                name="room[title]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="Room title"
              />
              <input
                name="room[slug]"
                class="block w-full rounded-md border-zinc-300 text-sm"
                placeholder="optional-slug"
              />
              <select
                name="room[coordinator_agent_id]"
                class="block w-full rounded-md border-zinc-300 text-sm"
              >
                <option value="">No coordinator</option>
                <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
              </select>
              <.button class="w-full">Create Room</.button>
            </.form>
          </aside>

          <section id="agent-studio-room" class="rounded-lg border border-zinc-200 bg-white p-5">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="text-base font-semibold text-zinc-950">
                  {if selected_room(assigns), do: selected_room(assigns).title, else: "Room Chat"}
                </h2>
                <p class="mt-1 text-sm text-zinc-500">
                  Shared transcript with mention routing and coordinator fallback.
                </p>
              </div>
              <a
                :if={@room_id}
                href={~p"/api/v1/workspaces/#{@workspace_id}/rooms/#{@room_id}/transcript"}
                class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
              >
                Export
              </a>
            </div>

            <.form
              for={%{}}
              as={:room_filter}
              phx-change="filter-room-messages"
              class="mt-4 grid gap-2 md:grid-cols-[1fr_120px_130px_130px]"
            >
              <input
                name="room_filter[query]"
                value={filter_value(@room_filters, :query)}
                class="rounded-md border-zinc-300 text-sm"
                placeholder="Search transcript"
              />
              <select
                name="room_filter[author_type]"
                class="rounded-md border-zinc-300 text-sm"
              >
                <option value="">Any author</option>
                <option value="user" selected={filter_value(@room_filters, :author_type) == "user"}>
                  User
                </option>
                <option value="agent" selected={filter_value(@room_filters, :author_type) == "agent"}>
                  Agent
                </option>
                <option
                  value="system"
                  selected={filter_value(@room_filters, :author_type) == "system"}
                >
                  System
                </option>
              </select>
              <select
                name="room_filter[source_channel]"
                class="rounded-md border-zinc-300 text-sm"
              >
                <option value="">Any channel</option>
                <option
                  value="web"
                  selected={filter_value(@room_filters, :source_channel) == "web"}
                >
                  Web
                </option>
                <option
                  value="telegram"
                  selected={filter_value(@room_filters, :source_channel) == "telegram"}
                >
                  Telegram
                </option>
                <option
                  value="api"
                  selected={filter_value(@room_filters, :source_channel) == "api"}
                >
                  API
                </option>
              </select>
              <select
                name="room_filter[delivery_status]"
                class="rounded-md border-zinc-300 text-sm"
              >
                <option value="">Any delivery</option>
                <option
                  value="pending"
                  selected={filter_value(@room_filters, :delivery_status) == "pending"}
                >
                  Pending
                </option>
                <option
                  value="sent"
                  selected={filter_value(@room_filters, :delivery_status) == "sent"}
                >
                  Sent
                </option>
                <option
                  value="failed"
                  selected={filter_value(@room_filters, :delivery_status) == "failed"}
                >
                  Failed
                </option>
              </select>
            </.form>

            <div
              id="agent-studio-room-messages"
              class="mt-5 min-h-[18rem] space-y-3 rounded-lg border border-zinc-200 bg-zinc-50 p-3"
            >
              <div
                :for={message <- @room_messages}
                id={"agent-studio-room-message-#{message.id}"}
                class={[
                  "rounded-lg border bg-white p-3",
                  message.author_type == "agent" && "border-emerald-200",
                  message.author_type == "user" && "border-zinc-200",
                  message.author_type == "system" && "border-amber-200"
                ]}
              >
                <div class="flex items-center justify-between gap-3 text-xs text-zinc-500">
                  <span class="font-semibold uppercase tracking-[0.12em]">
                    {message.author_type}
                    <%= if message.agent do %>
                      · {message.agent.name}
                    <% end %>
                  </span>
                  <span>{message.source_channel}</span>
                </div>
                <p class="mt-2 whitespace-pre-wrap text-sm leading-6 text-zinc-700">
                  {message.content}
                </p>
                <div
                  :if={message.deliveries != []}
                  class="mt-2 flex flex-wrap gap-2 text-xs font-medium"
                >
                  <span
                    :for={delivery <- message.deliveries}
                    class={delivery_status_class(delivery.status)}
                  >
                    {delivery.provider}:{delivery.status}
                  </span>
                </div>
                <div
                  :if={message.metadata["proposal_status"] == "pending_multi_agent_response"}
                  class="mt-3 flex items-center justify-between gap-3 rounded-md bg-amber-50 p-2"
                >
                  <p class="text-xs font-medium text-amber-900">
                    {length(message.metadata["pending_agent_ids"] || [])} agents requested
                  </p>
                  <button
                    type="button"
                    phx-click="approve-room-proposal"
                    phx-value-message_id={message.id}
                    class="rounded-md bg-amber-900 px-2 py-1 text-xs font-medium text-white"
                  >
                    Approve
                  </button>
                </div>
              </div>
              <p :if={@room_messages == []} class="p-4 text-sm text-zinc-500">
                Start a room conversation or mention an agent with @handle.
              </p>
            </div>

            <.form
              for={%{}}
              as={:room_message}
              phx-submit="send-room-message"
              class="mt-4 flex gap-3"
            >
              <input
                name="room_message[content]"
                class="min-w-0 flex-1 rounded-md border-zinc-300 text-sm"
                placeholder="Message the room..."
              />
              <.button>Send</.button>
            </.form>
          </section>

          <aside class="space-y-4">
            <section class="rounded-lg border border-zinc-200 bg-white p-4">
              <h2 class="text-base font-semibold text-zinc-950">Room Members</h2>
              <div class="mt-4 space-y-2">
                <div
                  :for={member <- (selected_room(assigns) && selected_room(assigns).members) || []}
                  id={"agent-studio-room-member-#{member.id}"}
                  class="rounded-lg border border-zinc-200 p-3"
                >
                  <p class="truncate text-sm font-medium text-zinc-950">{member.agent.name}</p>
                  <p class="mt-1 text-xs text-zinc-500">
                    @{member.mention_handle} · {member.role} · {member.response_mode}
                  </p>
                </div>
                <p
                  :if={is_nil(selected_room(assigns)) || selected_room(assigns).members == []}
                  class="text-sm text-zinc-500"
                >
                  No members in this room.
                </p>
              </div>

              <.form for={%{}} as={:member} phx-submit="add-room-member" class="mt-5 space-y-3">
                <select
                  name="member[agent_id]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                >
                  <option value="">Select agent</option>
                  <option :for={agent <- @agents} value={agent.id}>{agent.name}</option>
                </select>
                <input
                  name="member[mention_handle]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                  placeholder="mention-handle"
                />
                <div class="grid grid-cols-2 gap-3">
                  <select name="member[role]" class="rounded-md border-zinc-300 text-sm">
                    <option value="participant">Participant</option>
                    <option value="coordinator">Coordinator</option>
                    <option value="observer">Observer</option>
                  </select>
                  <select name="member[response_mode]" class="rounded-md border-zinc-300 text-sm">
                    <option value="on_mention">On mention</option>
                    <option value="coordinator">Coordinator</option>
                    <option value="silent">Silent</option>
                  </select>
                </div>
                <.button class="w-full">Add Member</.button>
              </.form>
            </section>

            <section class="rounded-lg border border-zinc-200 bg-white p-4">
              <h2 class="text-base font-semibold text-zinc-950">Telegram</h2>
              <div class="mt-4 space-y-2">
                <div
                  :for={
                    binding <-
                      (selected_room(assigns) && selected_room(assigns).channel_bindings) ||
                        []
                  }
                  id={"agent-studio-room-binding-#{binding.id}"}
                  class="rounded-lg border border-zinc-200 p-3"
                >
                  <% setup_status = telegram_setup_status(binding) %>
                  <% setup = telegram_setup_readiness(binding) %>
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="truncate text-sm font-medium text-zinc-950">/{binding.slug}</p>
                      <p class={[
                        "mt-1 text-xs font-semibold",
                        telegram_setup_status_class(setup_status)
                      ]}>
                        {telegram_setup_status_label(setup_status)}
                      </p>
                    </div>
                    <div class="flex gap-2">
                      <button
                        type="button"
                        phx-click="test-room-binding"
                        phx-value-binding_id={binding.id}
                        class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                      >
                        Test
                      </button>
                      <button
                        type="button"
                        phx-click="retry-room-binding"
                        phx-value-binding_id={binding.id}
                        class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                      >
                        Retry
                      </button>
                    </div>
                  </div>
                  <p class="mt-1 text-xs text-zinc-500">
                    {binding.provider} · {binding.status} · {binding.external_chat_id || "unbound"}
                  </p>
                  <p
                    :if={telegram_capture_pending?(binding)}
                    class="mt-1 text-xs font-medium text-amber-700"
                  >
                    Waiting for first Telegram message to capture chat id.
                  </p>
                  <p class="mt-1 break-all text-xs text-zinc-500">
                    {setup["webhook_url"]}
                  </p>
                  <p class="mt-1 text-xs text-zinc-500">
                    deliveries sent {get_in(setup, ["delivery_counts", "sent"])} · pending {get_in(
                      setup,
                      [
                        "delivery_counts",
                        "pending"
                      ]
                    )} · failed {get_in(setup, ["delivery_counts", "failed"])}
                  </p>
                  <div class="mt-3 space-y-1" id={"agent-studio-telegram-setup-#{binding.id}"}>
                    <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                      Telegram Production Setup
                    </p>
                    <div class="grid gap-1">
                      <div
                        :for={item <- telegram_setup_items(binding)}
                        class={[
                          "rounded-md border px-2 py-1 text-xs",
                          telegram_setup_item_class(item["status"])
                        ]}
                      >
                        <span class="font-semibold">{item["label"]}</span>
                        <span class="ml-1">{item["text"]}</span>
                      </div>
                    </div>
                  </div>
                  <pre class="mt-2 overflow-auto rounded-md bg-zinc-950 p-2 text-[11px] text-white"><%= setup["set_webhook_command"] %></pre>
                  <p :if={binding.last_error != %{}} class="mt-2 text-xs text-red-700">
                    {binding.last_error["reason"] || inspect(binding.last_error)}
                  </p>
                </div>
                <p
                  :if={
                    is_nil(selected_room(assigns)) ||
                      selected_room(assigns).channel_bindings == []
                  }
                  class="text-sm text-zinc-500"
                >
                  No Telegram bindings.
                </p>
              </div>

              <.form
                for={%{}}
                as={:binding}
                phx-submit="create-room-binding"
                class="mt-5 space-y-3"
              >
                <input
                  name="binding[slug]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                  placeholder="webhook-slug"
                />
                <input
                  name="binding[external_chat_id]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                  placeholder="Telegram chat id"
                />
                <input
                  name="binding[token_env]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                  placeholder="TELEGRAM_BOT_TOKEN"
                />
                <input
                  name="binding[secret_env]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                  placeholder="optional secret env"
                />
                <.button class="w-full">Bind Telegram</.button>
              </.form>
            </section>

            <section class="rounded-lg border border-zinc-200 bg-white p-4">
              <h2 class="text-base font-semibold text-zinc-950">Delivery Receipts</h2>
              <div id="agent-studio-room-deliveries" class="mt-4 space-y-2">
                <div
                  :for={delivery <- @room_deliveries}
                  id={"agent-studio-room-delivery-#{delivery.id}"}
                  class="rounded-lg border border-zinc-200 p-3 text-xs"
                >
                  <div class="flex items-start justify-between gap-3">
                    <p class={["font-semibold", delivery_status_class(delivery.status)]}>
                      {delivery.provider} / {delivery.status}
                    </p>
                    <button
                      :if={delivery.status == "failed"}
                      type="button"
                      phx-click="retry-room-delivery"
                      phx-value-delivery_id={delivery.id}
                      class="rounded-md border border-zinc-200 px-2 py-1 font-medium text-zinc-700"
                    >
                      Retry
                    </button>
                  </div>
                  <p class="mt-1 text-zinc-500">
                    message {delivery.message_id} · attempts {delivery.attempts}
                  </p>
                  <p :if={delivery.last_error != %{}} class="mt-1 break-words text-red-700">
                    {delivery.last_error["reason"] || inspect(delivery.last_error)}
                  </p>
                </div>
                <p :if={@room_deliveries == []} class="text-sm text-zinc-500">
                  No delivery receipts yet.
                </p>
              </div>
            </section>

            <section
              id="starter-agent-packs-panel"
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <h2 class="text-base font-semibold text-zinc-950">Starter Agent Packs</h2>
              <div id="starter-agent-packs" class="mt-4 space-y-3">
                <div
                  :for={pack <- @starter_packs}
                  id={"starter-agent-pack-#{pack["slug"]}"}
                  class="rounded-lg border border-zinc-200 p-3"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <p class="truncate text-sm font-semibold text-zinc-950">{pack["name"]}</p>
                      <p class="mt-1 text-xs text-zinc-500">{pack["role"]}</p>
                    </div>
                    <button
                      type="button"
                      phx-click="import-starter-pack"
                      phx-value-slug={pack["slug"]}
                      class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                    >
                      Import
                    </button>
                  </div>
                  <p class="mt-2 text-xs leading-5 text-zinc-600">{pack["description"]}</p>
                  <p
                    :if={(pack["connector_requirements"] || []) != []}
                    class="mt-2 text-xs text-zinc-500"
                  >
                    Connectors: {pack["connector_requirements"] |> Enum.join(", ")}
                  </p>
                  <p
                    :if={(pack["automation_recipes"] || []) != []}
                    class="mt-1 text-xs text-zinc-500"
                  >
                    Recipes: {pack["automation_recipes"] |> Enum.join(", ")}
                  </p>
                </div>
                <p :if={@starter_packs == []} class="text-sm text-zinc-500">
                  No starter packs available.
                </p>
              </div>
            </section>

            <section id="agent-builder" class="rounded-lg border border-zinc-200 bg-white p-4">
              <h2 class="text-base font-semibold text-zinc-950">Guided Builder</h2>
              <.form
                for={%{}}
                as={:builder}
                phx-change="preview-builder-agent"
                phx-submit="create-builder-agent"
                class="mt-4 space-y-3"
              >
                <input
                  name="builder[name]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                  placeholder="Agent name"
                />
                <select name="builder[preset]" class="block w-full rounded-md border-zinc-300 text-sm">
                  <option :for={{key, _preset} <- @builder_presets} value={key}>
                    {String.replace(key, "_", " ") |> String.capitalize()}
                  </option>
                </select>
                <input
                  name="builder[default_provider]"
                  class="block w-full rounded-md border-zinc-300 text-sm"
                  placeholder="default provider, e.g. mock"
                />
                <textarea
                  name="builder[system_prompt]"
                  class="block min-h-[5rem] w-full rounded-md border-zinc-300 text-sm"
                  placeholder="Optional system prompt"
                ></textarea>
                <.button class="w-full">Create Agent</.button>
              </.form>
              <div
                :if={@builder_preview}
                id="agent-builder-preview"
                class="mt-4 rounded-lg border border-zinc-200 p-3"
              >
                <p class="text-xs font-semibold uppercase tracking-[0.12em] text-zinc-500">
                  Policy Preview
                </p>
                <p class="mt-2 text-sm font-medium text-zinc-950">
                  {@builder_preview["agent"]["name"]}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  Tools: {@builder_preview["policy"]["tool_bundles"] |> Enum.join(", ")}
                </p>
                <p class="mt-1 text-xs text-zinc-500">
                  Approval: {if @builder_preview["policy"]["requires_approval"],
                    do: "required",
                    else: "not required"}
                </p>
              </div>
              <p :if={@builder_result} class="mt-3 text-sm text-zinc-600">
                Created {@builder_result["agent"]["name"]} with {@builder_result["policy"][
                  "tool_bundles"
                ]
                |> Enum.join(", ")}.
              </p>
            </section>
          </aside>
        </section>

        <section class="rounded-lg border border-zinc-200 bg-white p-4">
          <form phx-change="select-agent" class="grid gap-3 md:grid-cols-[240px_220px_1fr]">
            <select name="agent_id" class="rounded-md border border-zinc-200 px-3 py-2 text-sm">
              <option :for={agent <- @agents} value={agent.id} selected={agent.id == @agent_id}>
                {agent.name}
              </option>
            </select>
            <select name="mode" class="rounded-md border border-zinc-200 px-3 py-2 text-sm">
              <option :for={{label, value} <- @modes} value={value} selected={value == @mode}>
                {label}
              </option>
            </select>
            <p class="self-center text-sm text-zinc-600">
              {@mode == "sandbox" && "No durable writes"}
              {@mode == "memory_proposals" && "Only memory proposals may be written"}
              {@mode == "live" && "Durable writes enabled"}
            </p>
          </form>
        </section>

        <div class="grid gap-6 xl:grid-cols-[1fr_360px]">
          <section class="rounded-lg border border-zinc-200 bg-white p-5">
            <h2 class="text-base font-semibold text-zinc-950">Sandbox Prompt</h2>
            <.form for={%{}} as={:studio} phx-submit="run-sandbox" class="mt-4 space-y-3">
              <input type="hidden" name="studio[mode]" value={@mode} />
              <textarea
                name="studio[prompt]"
                class="block min-h-[10rem] w-full rounded-lg border-zinc-300 text-zinc-900 focus:border-zinc-400 focus:ring-0 sm:text-sm"
                placeholder="Ask the selected agent something..."
              ><%= @prompt %></textarea>
              <.button>Run</.button>
            </.form>

            <div :if={@studio_result} id="agent-studio-result" class="mt-6 space-y-4">
              <div class="rounded-lg border border-zinc-200 p-4">
                <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                  Response
                </p>
                <p class="mt-2 whitespace-pre-wrap text-sm leading-6 text-zinc-700">
                  {get_in(@studio_result, ["provider_response", "message", "content"])}
                </p>
              </div>
              <div class="rounded-lg border border-zinc-200 p-4">
                <p class="text-xs font-semibold uppercase tracking-[0.14em] text-zinc-500">
                  Context Window
                </p>
                <pre class="mt-2 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-white"><%= inspect(@studio_result["memory"], pretty: true) %></pre>
              </div>
            </div>
          </section>

          <aside class="space-y-4">
            <section class="rounded-lg border border-zinc-200 bg-white p-4">
              <h2 class="text-base font-semibold text-zinc-950">Eval Suites</h2>
              <div class="mt-4 space-y-2">
                <div
                  :for={suite <- @eval_suites}
                  id={"agent-studio-suite-#{suite.id}"}
                  class="flex items-center justify-between gap-3 rounded-lg border border-zinc-200 p-3"
                >
                  <p class="min-w-0 truncate text-sm font-medium text-zinc-950">{suite.name}</p>
                  <button
                    phx-click="run-eval-suite"
                    phx-value-suite_id={suite.id}
                    class="rounded-md border border-zinc-200 px-2 py-1 text-xs font-medium text-zinc-700"
                  >
                    Run
                  </button>
                </div>
                <p :if={@eval_suites == []} class="text-sm text-zinc-500">
                  No eval suites configured.
                </p>
              </div>
            </section>

            <section
              :if={@eval_result}
              id="agent-studio-eval-result"
              class="rounded-lg border border-zinc-200 bg-white p-4"
            >
              <h2 class="text-base font-semibold text-zinc-950">Eval Result</h2>
              <pre class="mt-3 overflow-auto rounded-md bg-zinc-950 p-3 text-xs text-white"><%= inspect(@eval_result, pretty: true) %></pre>
            </section>
          </aside>
        </div>
      <% else %>
        <section class="rounded-lg border border-zinc-200 bg-white p-8 text-sm text-zinc-500">
          No workspaces yet.
        </section>
      <% end %>
    </section>
    """
  end
end
