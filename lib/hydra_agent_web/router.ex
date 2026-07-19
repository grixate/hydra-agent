defmodule HydraAgentWeb.Router do
  use HydraAgentWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HydraAgentWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; base-uri 'self'; connect-src 'self'; font-src 'self'; form-action 'self'; frame-ancestors 'none'; frame-src 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'",
      "permissions-policy" => "camera=(), geolocation=(), microphone=(), payment=(), usb=()",
      "referrer-policy" => "strict-origin-when-cross-origin"
    }

    plug HydraAgentWeb.UserAuth, :fetch_current_user
  end

  pipeline :require_authenticated_user do
    plug HydraAgentWeb.UserAuth, :require_authenticated_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug HydraAgentWeb.Plugs.RateLimit, scope: "api_edge", config: :api_edge, identity: :remote
    plug HydraAgentWeb.Plugs.ApiAuth
    plug HydraAgentWeb.Plugs.RateLimit, scope: "api", config: :api, identity: :api_credential
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  pipeline :incoming_gateway do
    plug :accepts, ["json"]

    plug HydraAgentWeb.Plugs.RateLimit,
      scope: "incoming_gateway_edge",
      limit: 300,
      window_seconds: 60,
      identity: :remote
  end

  scope "/", HydraAgentWeb do
    pipe_through :health
    get "/healthz", HealthController, :live
    get "/readyz", HealthController, :ready
  end

  scope "/", HydraAgentWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
    get "/demo/simulations", SimLabController, :studies
    get "/demo/simulations/:id", SimLabController, :show
    get "/demo/simulations/:id/observatory", SimLabController, :observatory
    get "/demo/simulations/:id/forecast.md", SimLabController, :demo_export_forecast
  end

  scope "/", HydraAgentWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/lab/workspaces/:workspace_id/studies", SimLabController, :workspace_studies
    post "/lab/workspaces/:workspace_id/studies", SimLabController, :create
    get "/lab/workspaces/:workspace_id/studies/:id", SimLabController, :workspace_show

    get "/lab/workspaces/:workspace_id/studies/:id/behavior-model.md",
        SimLabController,
        :export_behavior_model

    post "/lab/workspaces/:workspace_id/studies/:id/notes", SimLabController, :add_note

    post "/lab/workspaces/:workspace_id/studies/:id/assumption-context",
         SimLabController,
         :start_assumption_context

    post "/lab/workspaces/:workspace_id/studies/:id/context/refresh",
         SimLabController,
         :synthesize_context

    post "/lab/workspaces/:workspace_id/studies/:id/research/codex-test",
         SimLabController,
         :start_codex_test_research

    post "/lab/workspaces/:workspace_id/studies/:id/research/web",
         SimLabController,
         :start_web_research

    post "/lab/workspaces/:workspace_id/studies/:id/uploads", SimLabController, :add_upload

    post "/lab/workspaces/:workspace_id/studies/:id/public-sources",
         SimLabController,
         :add_public_url

    post "/lab/workspaces/:workspace_id/studies/:id/sources/:source_id/remove",
         SimLabController,
         :remove_source

    post "/lab/workspaces/:workspace_id/studies/:id/evidence/:evidence_id/review",
         SimLabController,
         :review_evidence

    post "/lab/workspaces/:workspace_id/studies/:id/personas", SimLabController, :add_persona

    post "/lab/workspaces/:workspace_id/studies/:id/personas/:persona_id",
         SimLabController,
         :update_persona

    post "/lab/workspaces/:workspace_id/studies/:id/behavior-draft",
         SimLabController,
         :generate_behavior_draft

    post "/lab/workspaces/:workspace_id/studies/:id/patterns", SimLabController, :add_pattern

    post "/lab/workspaces/:workspace_id/studies/:id/patterns/:pattern_id",
         SimLabController,
         :update_pattern

    post "/lab/workspaces/:workspace_id/studies/:id/scenario-draft",
         SimLabController,
         :generate_scenario_draft

    post "/lab/workspaces/:workspace_id/studies/:id/scenarios", SimLabController, :add_scenario

    post "/lab/workspaces/:workspace_id/studies/:id/scenarios/:scenario_id",
         SimLabController,
         :update_scenario

    post "/lab/workspaces/:workspace_id/studies/:id/scenarios/:scenario_id/variants",
         SimLabController,
         :create_variant

    post "/lab/workspaces/:workspace_id/studies/:id/scenarios/:scenario_id/run",
         SimLabController,
         :run_scenario

    get "/lab/workspaces/:workspace_id/studies/:id/observatory/:run_id",
        SimLabController,
        :workspace_observatory

    post "/lab/workspaces/:workspace_id/studies/:id/observatory/:run_id/control-first-variant",
         SimLabController,
         :create_control_first_variant

    post "/lab/workspaces/:workspace_id/studies/:id/observatory/:run_id/cancel",
         SimLabController,
         :cancel_run

    get "/lab/workspaces/:workspace_id/studies/:id/compare",
        SimLabController,
        :workspace_compare

    get "/lab/workspaces/:workspace_id/studies/:id/reports/:run_id",
        SimLabController,
        :workspace_report

    get "/lab/workspaces/:workspace_id/studies/:id/reports/:run_id/export.md",
        SimLabController,
        :export_report

    post "/lab/workspaces/:workspace_id/studies/:id/reports/:run_id/calibrations",
         SimLabController,
         :record_calibration

    post "/lab/workspaces/:workspace_id/studies/:id/reports/:run_id/calibration-proposals/:pattern_id/apply",
         SimLabController,
         :apply_calibration_proposal

    get "/lab/studies", SimLabController, :workspace_entry
    get "/simulations", SimulationController, :index
    get "/simulations/new", SimulationController, :new
    post "/simulations", SimulationController, :create
    get "/simulations/:id", SimulationController, :show
    get "/simulations/:id/build", SimulationController, :build
    get "/simulations/:id/context", SimulationController, :context
    post "/simulations/:id/context/build", SimulationController, :build_context
    post "/simulations/:id/context/research", SimulationController, :research_context

    post "/simulations/:id/context/sources/:source_id/exclude",
         SimulationController,
         :exclude_context_source

    get "/simulations/:id/population", SimulationController, :population
    post "/simulations/:id/population/build", SimulationController, :build_population
    post "/simulations/:id/population/import", SimulationController, :import_population

    post "/simulations/:id/population/personas/:agent_id",
         SimulationController,
         :generate_persona

    post "/simulations/:id/population/attributes/:type_id/:attribute_key/exclude",
         SimulationController,
         :exclude_population_attribute

    get "/simulations/:id/script", SimulationController, :script
    post "/simulations/:id/script/build", SimulationController, :build_script
    get "/simulations/:id/script/export/:format", SimulationController, :export_script

    get "/simulations/:id/run", SimulationController, :run
    post "/simulations/:id/run/configuration", SimulationController, :configure_run
    post "/simulations/:id/run", SimulationController, :start_quick_run
    post "/simulations/:id/run/:run_id/cancel", SimulationController, :cancel_quick_run
    post "/simulations/:id/run/:run_id/replay", SimulationController, :replay_run
    post "/simulations/:id/run/:run_id/rerun", SimulationController, :rerun_fresh
    get "/simulations/:id/results", SimulationController, :results
    post "/simulations/:id/results/reports", SimulationController, :create_report
    get "/simulations/:id/results/export/:artifact", SimulationController, :export_results

    get "/simulations/:id/results/reports/:report_id/export/:format",
        SimulationController,
        :export_report

    get "/simulations/:id/compare", SimulationController, :compare
    post "/simulations/:id/duplicate", SimulationController, :duplicate
    post "/simulations/:id/archive", SimulationController, :archive
    get "/blueprints", BlueprintController, :index
    post "/blueprints/import", BlueprintController, :import
    get "/blueprints/:id", BlueprintController, :show
    get "/blueprints/:id/edit", BlueprintController, :edit
    patch "/blueprints/:id", BlueprintController, :update
    post "/blueprints/:id/duplicate", BlueprintController, :duplicate
    post "/blueprints/:id/test", BlueprintController, :test
    get "/blueprints/:id/export", BlueprintController, :export
    get "/account/security", SessionController, :security
    put "/account/security", SessionController, :update_password

    live_session :authenticated, on_mount: [{HydraAgentWeb.UserAuth, :ensure_authenticated}] do
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
  end

  scope "/api", HydraAgentWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/metrics", HealthController, :metrics
    get "/metrics/openmetrics", HealthController, :openmetrics

    scope "/v1" do
      get "/doctor", DoctorController, :show

      get "/workspaces/:workspace_id/sim_lab/studies/:study_id/runs/:run_id/snapshots",
          SimLabApiController,
          :snapshots

      get "/workspaces/:workspace_id/sim_lab/studies/:study_id/runs/:run_id/compare",
          SimLabApiController,
          :compare

      get "/workspaces/:workspace_id/sim_lab/studies/:study_id/runs/:run_id/snapshots/:tick",
          SimLabApiController,
          :snapshot

      get "/workspaces/:workspace_id/sim_lab/studies/:study_id/runs/:run_id/clusters/:cluster_id",
          SimLabApiController,
          :cluster

      get "/workspaces/:workspace_id/sim_lab/studies/:study_id/runs/:run_id/agents/:agent_id/trace",
          SimLabApiController,
          :agent_trace

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

  scope "/api/v1", HydraAgentWeb do
    pipe_through :incoming_gateway

    post "/webhooks/:slug", WebhookController, :receive
    post "/telegram/:binding_slug/webhook", TelegramController, :webhook
  end
end
