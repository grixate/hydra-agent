defmodule HydraAgentWeb.Router do
  use HydraAgentWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HydraAgentWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug HydraAgentWeb.Plugs.ApiAuth
  end

  scope "/", HydraAgentWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/dashboard", ControlLive, :index
    live "/missions", MissionLive, :index
    live "/missions/:id", MissionLive, :show
    live "/runs", RunIndexLive, :index
    live "/runs/:id", RunDetailLive, :show
    live "/agents", AgentDirectoryLive, :index
    live "/agents/:id", AgentDetailLive, :show
    live "/memory", MemoryStudioLive, :index
    live "/memory/:id", KnowledgeNodeLive, :show
    live "/graph", GraphWorkbenchLive, :index
    live "/graph/nodes/:id", KnowledgeNodeLive, :show
    live "/skills", SkillRegistryLive, :index
    live "/skills/:id", SkillDetailLive, :show
    live "/automations", AutomationLive, :index
    live "/agent-studio", AgentStudioLive, :index
    live "/settings", SettingsLive, :index
    live "/tools", ToolsProtocolsLive, :index
    live "/control", ControlLive, :index
    live "/control/missions", MissionLive, :index
    live "/control/missions/:id", MissionLive, :show
    live "/control/agents", AgentDirectoryLive, :index
    live "/control/agents/studio", AgentStudioLive, :index
    live "/control/agents/:id", AgentDetailLive, :show
    live "/control/automations", AutomationLive, :index
    live "/control/graph", GraphWorkbenchLive, :index
    live "/control/graph/nodes/:id", KnowledgeNodeLive, :show
    live "/control/memory", MemoryStudioLive, :index
    live "/control/memory/:id", KnowledgeNodeLive, :show
    live "/control/runtime", RuntimeOperationsLive, :index
    live "/control/settings", SettingsLive, :index
    live "/control/runs", RunIndexLive, :index
    live "/control/runs/:id", RunDetailLive, :show
    live "/control/skills", SkillRegistryLive, :index
    live "/control/skills/:id", SkillDetailLive, :show
    live "/control/tools", ToolsProtocolsLive, :index
  end

  scope "/api", HydraAgentWeb do
    pipe_through :api

    get "/health", HealthController, :show

    scope "/v1" do
      get "/doctor", DoctorController, :show

      resources "/workspaces", WorkspaceController, only: [:index, :create, :show] do
        get "/doctor", DoctorController, :show
        post "/agents/import_pack", AgentController, :import_pack
        resources "/agents", AgentController, only: [:index, :create]
        post "/agent_builder/preview", AgentBuilderController, :preview
        post "/agent_builder/create", AgentBuilderController, :create
        resources "/conversations", ConversationController, only: [:index, :create]
        resources "/automations", AutomationController, only: [:index, :create]
        get "/automation_recipes", AutomationController, :recipes
        post "/automation_recipes/:recipe_id", AutomationController, :create_from_recipe
        resources "/webhooks", WebhookController, only: [:index, :create]
        get "/audit/export", AuditController, :export
        get "/eval_suites", EvalController, :suites
        post "/eval_suites", EvalController, :create_suite
        get "/evals/benchmark", EvalController, :benchmark
        post "/evals/benchmarks/seed", EvalController, :seed_benchmarks
        resources "/providers", ProviderController, only: [:index, :create, :show]
        get "/providers/:id/health", ProviderController, :health
        get "/providers/:id/models", ProviderController, :models
        get "/connectors/specs", ConnectorController, :specs
        get "/connectors/actions", ConnectorController, :actions
        resources "/connectors", ConnectorController, only: [:index, :create]
        post "/connectors/:id/health", ConnectorController, :health
        post "/connectors/:id/agent_grants", ConnectorController, :grant_agent
        post "/connectors/:account_id/actions", ConnectorController, :request_action
        post "/connector_actions/:action_id/approve", ConnectorController, :approve_action
        post "/connector_actions/:action_id/reject", ConnectorController, :reject_action
        resources "/rooms", RoomController, only: [:index, :create, :show, :update]
        post "/rooms/:id/members", RoomController, :create_member
        delete "/rooms/:id/members/:agent_id", RoomController, :delete_member
        get "/rooms/:id/messages", RoomController, :messages
        post "/rooms/:id/messages", RoomController, :send_message
        get "/rooms/:id/transcript", RoomController, :transcript
        get "/rooms/:id/deliveries", RoomController, :deliveries
        post "/rooms/:id/deliveries/:delivery_id/retry", RoomController, :retry_delivery
        post "/rooms/:id/messages/:message_id/approve", RoomController, :approve_proposal
        get "/rooms/:id/channel_bindings", RoomController, :channel_bindings
        post "/rooms/:id/channel_bindings", RoomController, :create_channel_binding

        post "/rooms/:id/channel_bindings/:binding_id/retry",
             RoomController,
             :retry_channel_binding

        get "/credential_pools", ProviderController, :credential_pools
        post "/credential_pools", ProviderController, :create_credential_pool
        post "/credential_pools/:id/items", ProviderController, :create_credential_pool_item
        resources "/budgets", BudgetController, only: [:index, :create]
        resources "/skills", SkillController, only: [:index, :create]
        get "/skills/usage", SkillController, :usage
        get "/skills/improvement_proposals", SkillController, :improvement_proposals
        get "/skills/experiments", SkillController, :experiments
        get "/skill_imports", SkillController, :imports
        post "/skill_imports/scan", SkillController, :scan_import
        post "/skill_imports/:import_id/approve", SkillController, :approve_import
        post "/skill_imports/:import_id/reject", SkillController, :reject_import
        post "/skills/import_markdown", SkillController, :import_markdown
        post "/skills/import_directory", SkillController, :import_directory
        post "/skills/propose_from_run/:run_id", SkillController, :propose_from_run

        post "/skills/propose_from_conversation/:conversation_id",
             SkillController,
             :propose_from_conversation

        post "/skills/propose_from_room/:room_id", SkillController, :propose_from_room
        post "/skills/seed_pack", SkillController, :seed_pack
        post "/skills/code_skill", SkillController, :create_code_skill
        resources "/tool_policies", ToolPolicyController, only: [:index, :create, :show]
        resources "/mcp_servers", McpController, only: [:index, :create]
        get "/memory/proposals", MemoryController, :proposals
        resources "/missions", MissionController, only: [:index, :create, :show, :update]
        post "/missions/:id/start", MissionController, :start
        resources "/runs", RunController, only: [:index, :create, :show]
        post "/runs/:id/start", RunController, :start
        post "/runs/:id/pause", RunController, :pause
        post "/runs/:id/resume", RunController, :resume
        post "/runs/:id/cancel", RunController, :cancel
        post "/runs/:id/retry", RunController, :retry
        post "/runs/:id/fork", RunController, :fork
        get "/runs/:id/trace", RunController, :trace
        post "/runs/:id/steer", RunController, :steer
        post "/runs/:id/plan", RunController, :plan
        post "/runs/:id/generate_plan", RunController, :generate_plan
        post "/runs/:id/execute_next", RunController, :execute_next
        post "/runs/:id/execute_parallel", RunController, :execute_parallel
        post "/runs/:id/start_worker", RunController, :start_worker
        post "/runs/:id/stop_worker", RunController, :stop_worker
        post "/runs/:id/steps/:step_id/approve", RunController, :approve_step
        post "/runs/:id/steps/:step_id/reject", RunController, :reject_step
        resources "/knowledge/nodes", KnowledgeController, only: [:index, :create]
        get "/knowledge/nodes/:id", KnowledgeController, :show
        get "/knowledge/relationships", KnowledgeController, :relationships
        post "/knowledge/relationships", KnowledgeController, :create_relationship
        get "/knowledge/relationships/:id", KnowledgeController, :show_relationship
        post "/knowledge/type_definitions/seed", KnowledgeController, :seed_types
        post "/memory/curate", MemoryController, :curate
        get "/safety/events", SafetyController, :index
        get "/usage", UsageController, :index
        get "/approvals", ApprovalController, :index
        get "/checkpoints", CheckpointController, :index
        get "/checkpoints/:id/diff", CheckpointController, :diff
        post "/checkpoints/:id/restore", CheckpointController, :restore
      end

      get "/agents/starter_packs", AgentController, :starter_packs
      get "/agents/pack_schema", AgentController, :pack_schema
      post "/agents/import_pack", AgentController, :import_pack
      resources "/agents", AgentController, only: [:create, :show]
      get "/agents/:id/export_pack", AgentController, :export_pack
      post "/agents/:id/chat", AgentController, :chat
      post "/agents/:id/memory/proposals", MemoryController, :propose
      post "/memory/proposals/:id/promote", MemoryController, :promote_proposal
      post "/memory/proposals/:id/reject", MemoryController, :reject_proposal
      resources "/conversations", ConversationController, only: [:create, :show]
      post "/conversations/:id/messages", ConversationController, :message
      post "/conversations/:id/stream", ConversationController, :stream_message
      resources "/automations", AutomationController, only: [:create, :show, :update]
      post "/automations/:id/run", AutomationController, :run
      resources "/webhooks", WebhookController, only: [:create, :show]
      post "/webhooks/:slug", WebhookController, :receive
      post "/telegram/:binding_slug/webhook", TelegramController, :webhook

      resources "/eval_suites", EvalController, only: [] do
        post "/cases", EvalController, :create_case
      end

      get "/eval_suites/:id", EvalController, :show_suite
      post "/eval_runs", EvalController, :create_run
      get "/eval_runs/:id", EvalController, :show_run
      post "/eval_runs/:id/execute", EvalController, :execute_run
      get "/eval_runs/:id/report", EvalController, :report
      resources "/providers", ProviderController, only: [:create, :show]
      get "/providers/:id/health", ProviderController, :health
      get "/providers/:id/models", ProviderController, :models
      resources "/budgets", BudgetController, only: [:create, :show]
      resources "/skills", SkillController, only: [:create, :show]
      get "/skills/:id/export_markdown", SkillController, :export_markdown
      post "/skills/:id/eval_suite", SkillController, :generate_eval_suite
      post "/skills/:id/experiments", SkillController, :run_experiment
      post "/skills/:id/improvement_proposals/refine", SkillController, :refine_proposal
      post "/skills/:id/improvement_proposals/prune", SkillController, :prune_proposal
      post "/skills/:id/test", SkillController, :test
      post "/skills/:id/activate", SkillController, :activate
      post "/skills/:id/deprecate", SkillController, :deprecate
      post "/skills/:id/archive", SkillController, :archive
      post "/skill_improvement_proposals/:id/approve", SkillController, :approve_proposal
      post "/skill_improvement_proposals/:id/reject", SkillController, :reject_proposal
      get "/tools/bundles", ToolController, :bundles
      get "/tools", ToolController, :index
      resources "/mcp_servers", McpController, only: [:create, :show, :update]
      resources "/tool_policies", ToolPolicyController, only: [:create, :show]
      resources "/missions", MissionController, only: [:create, :show, :update]
      post "/missions/:id/start", MissionController, :start
      resources "/runs", RunController, only: [:create, :show]
      post "/runs/:id/start", RunController, :start
      post "/runs/:id/pause", RunController, :pause
      post "/runs/:id/resume", RunController, :resume
      post "/runs/:id/cancel", RunController, :cancel
      post "/runs/:id/retry", RunController, :retry
      post "/runs/:id/fork", RunController, :fork
      get "/runs/:id/trace", RunController, :trace
      get "/checkpoints/:id/diff", CheckpointController, :diff
      post "/checkpoints/:id/restore", CheckpointController, :restore
      post "/runs/:id/steer", RunController, :steer
      post "/runs/:id/plan", RunController, :plan
      post "/runs/:id/generate_plan", RunController, :generate_plan
      post "/runs/:id/execute_next", RunController, :execute_next
      post "/runs/:id/execute_parallel", RunController, :execute_parallel
      post "/runs/:id/start_worker", RunController, :start_worker
      post "/runs/:id/stop_worker", RunController, :stop_worker
      post "/runs/:id/steps/:step_id/approve", RunController, :approve_step
      post "/runs/:id/steps/:step_id/reject", RunController, :reject_step
      resources "/knowledge/nodes", KnowledgeController, only: [:create]
      get "/knowledge/nodes/:id", KnowledgeController, :show
      post "/knowledge/relationships", KnowledgeController, :create_relationship
      get "/knowledge/relationships/:id", KnowledgeController, :show_relationship
    end
  end
end
