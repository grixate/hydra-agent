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
  end

  scope "/", HydraAgentWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/control", ControlLive, :index
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
        resources "/conversations", ConversationController, only: [:index, :create]
        resources "/automations", AutomationController, only: [:index, :create]
        resources "/webhooks", WebhookController, only: [:index, :create]
        get "/audit/export", AuditController, :export
        get "/eval_suites", EvalController, :suites
        post "/eval_suites", EvalController, :create_suite
        resources "/providers", ProviderController, only: [:index, :create]
        resources "/budgets", BudgetController, only: [:index, :create]
        resources "/skills", SkillController, only: [:index, :create]
        resources "/tool_policies", ToolPolicyController, only: [:index, :create]
        resources "/runs", RunController, only: [:index]
        resources "/knowledge/nodes", KnowledgeController, only: [:index]
        get "/knowledge/relationships", KnowledgeController, :relationships
        post "/knowledge/type_definitions/seed", KnowledgeController, :seed_types
        post "/memory/curate", MemoryController, :curate
        get "/safety/events", SafetyController, :index
        get "/usage", UsageController, :index
        get "/approvals", ApprovalController, :index
      end

      resources "/agents", AgentController, only: [:create, :show]
      post "/agents/import_pack", AgentController, :import_pack
      get "/agents/:id/export_pack", AgentController, :export_pack
      post "/agents/:id/chat", AgentController, :chat
      resources "/conversations", ConversationController, only: [:create, :show]
      post "/conversations/:id/messages", ConversationController, :message
      post "/conversations/:id/stream", ConversationController, :stream_message
      resources "/automations", AutomationController, only: [:create, :show, :update]
      post "/automations/:id/run", AutomationController, :run
      resources "/webhooks", WebhookController, only: [:create, :show]
      post "/webhooks/:slug", WebhookController, :receive

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
      post "/skills/:id/test", SkillController, :test
      post "/skills/:id/activate", SkillController, :activate
      post "/skills/:id/deprecate", SkillController, :deprecate
      post "/skills/:id/archive", SkillController, :archive
      get "/tools", ToolController, :index
      resources "/tool_policies", ToolPolicyController, only: [:create, :show]
      resources "/runs", RunController, only: [:create, :show]
      post "/runs/:id/start", RunController, :start
      post "/runs/:id/pause", RunController, :pause
      post "/runs/:id/resume", RunController, :resume
      post "/runs/:id/cancel", RunController, :cancel
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
      post "/knowledge/relationships", KnowledgeController, :create_relationship
    end
  end
end
