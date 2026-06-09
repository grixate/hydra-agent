# V4 Productization Notes

Hydra V4 focuses on making the runtime useful as an everyday agent OS: Telegram rooms, auditable connector actions, safe skill imports, recipe-ready automations, and browser-backed research.

## Docker VPS Deployment

1. Create a production `.env` beside `docker-compose.prod.yml`.
2. Set at least:
   - `PHX_HOST`
   - `SECRET_KEY_BASE`
   - `POSTGRES_PASSWORD`
   - `HYDRA_ADMIN_USERNAME`
   - `HYDRA_ADMIN_PASSWORD`
   - `HYDRA_API_TOKEN`
   - `HYDRA_BROWSER_WORKER_TOKEN`
   - `TELEGRAM_BOT_TOKEN`
   - `TELEGRAM_WEBHOOK_SECRET`
3. Start Hydra:

```bash
docker compose -f docker-compose.prod.yml --profile migrate run --rm migrate
docker compose -f docker-compose.prod.yml up -d --build
docker compose -f docker-compose.prod.yml --profile smoke run --rm smoke
```

The production compose file runs Caddy, Postgres, Hydra, and the Playwright browser worker. Caddy is the only public HTTP service and proxies HTTPS traffic to the app over the internal Docker network. Hydra talks to the browser worker through `HYDRA_BROWSER_WORKER_URL=http://browser-worker:4100/actions` and signs action requests with `HYDRA_BROWSER_WORKER_TOKEN`. The worker is built from `services/browser-worker` with pinned Playwright dependencies so the deploy image owns its Node runtime instead of relying on a bind-mounted script.

Browser management routes are protected by the env-backed admin credentials. JSON APIs are protected by `HYDRA_API_TOKEN` by default. `GET /api/health` remains public for load balancers and container health checks. Webhook ingress routes remain publicly reachable but verify their own configured bearer or secret tokens.

Run the local preflight before deployment:

```bash
scripts/prod-env-check.sh
```

After deployment, run the global and workspace doctor checks:

```bash
curl -H "authorization: Bearer $HYDRA_API_TOKEN" "https://$PHX_HOST/api/v1/doctor"
curl -H "authorization: Bearer $HYDRA_API_TOKEN" "https://$PHX_HOST/api/v1/workspaces/$WORKSPACE_ID/doctor"
```

The global doctor checks database access, migration state, auth envs, backup configuration, tool registry integrity, starter pack validity, OTP process registration, runtime pressure, browser worker action auth, and browser worker health. The workspace doctor adds provider health, Telegram binding readiness, connector env/config readiness, automation connector readiness blockers, and active MCP server readiness.

The `smoke` profile runs the same doctor checks through the production release
command and exits non-zero if any check is an error. Set
`HYDRA_SMOKE_WORKSPACE_ID` to include workspace-scoped readiness, and set
`HYDRA_SMOKE_FAIL_ON_WARNING=true` when warnings should fail a deployment gate.

### Backup And Restore

Before every upgrade, create a Postgres backup:

```bash
scripts/prod-backup.sh
```

Prove that a backup can restore into a fresh Compose project and still pass
migrations plus release smoke checks:

```bash
scripts/prod-restore-smoke.sh backups/hydra-agent-YYYYMMDDTHHMMSSZ.sql
```

Set `HYDRA_BACKUP_CONFIGURED=true` in production once an external backup schedule is in place.

The full production runbook is in `docs/production-runbooks.md`. The current
no-VPS readiness boundary is tracked in `docs/production-readiness.md`.

## Telegram Setup Wizard

Agent Studio now exposes the first production setup path:

1. Create or select a room.
2. Create a `telegram` room channel binding with:
   - `slug`
   - `external_chat_id`, or leave it blank to capture the first inbound chat id
   - `token_env=TELEGRAM_BOT_TOKEN`
   - `secret_env=TELEGRAM_WEBHOOK_SECRET`
3. Register the Telegram webhook using the generated path and command shown in the UI:

```bash
curl -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
  -H "content-type: application/json" \
  -d "{\"url\":\"https://$PHX_HOST/api/v1/telegram/$BINDING_SLUG/webhook\",\"secret_token\":\"$TELEGRAM_WEBHOOK_SECRET\"}"
```

4. Send a Telegram message into the chat.
5. Confirm Hydra records the inbound room message, agent reply, and per-message delivery receipt.

If a binding is created without an external chat id, Hydra stores it as `pending:<slug>` with chat capture enabled. The first valid Telegram webhook with the expected secret token binds the real chat id and disables capture. Agent Studio includes a Telegram production setup checklist for public `PHX_HOST`, webhook URL, `setWebhook` command, token env refs, secret-token readiness, chat capture, inbound proof, outbound proof, delivery receipt counts, failed-delivery retry state, and last error state. Room channel-binding API responses expose the same `telegram_setup` readiness object. Test sends are blocked locally while chat capture is still pending. Agent Studio also includes transcript filters and per-message delivery receipts with failed-delivery retry controls.

## Connector Safety Model

Connector accounts store env-var references, never raw credentials. Connector actions are durable records:

- Read and draft actions execute immediately.
- Agent-initiated writes fail closed unless the connector account explicitly grants that agent the requested write action.
- External writes enter `awaiting_approval`.
- Trusted execution only bypasses approval when the agent has a trusted connector grant.
- Approved writes execute through native provider APIs, an optional provider endpoint, or are recorded as approved when no endpoint is configured.
- Rejected writes never execute.

Daily OS connector providers seeded in V4 are `email`, `calendar`, `notion`, `notes`, `youtube`, `x`, `linkedin`, and `telegram`.

Native provider coverage currently includes:

- Gmail search/read/send via `EMAIL_ACCESS_TOKEN`.
- Google Calendar list/create event via `CALENDAR_ACCESS_TOKEN`.
- YouTube search/metadata via `YOUTUBE_API_KEY`.
- Notion create page/append note via `NOTION_TOKEN` and configured parent/page ids.
- Hydra workspace notes append without external credentials.
- X post publishing via `X_ACCESS_TOKEN` and the X API `POST /2/tweets` endpoint.
- LinkedIn post publishing via `LINKEDIN_ACCESS_TOKEN`, `author_urn`, and the LinkedIn REST Posts API.
- Telegram connector setup via `TELEGRAM_BOT_TOKEN` for draft/send approval records; room delivery still uses Telegram room channel bindings.

The Tools and Protocols UI can create connector accounts with config JSON, show setup scopes/config fields, run health checks, grant per-agent connector write permissions, request actions, approve/reject pending writes, and inspect action results. Each provider exposes an operator setup guide with required env refs, scopes, config field explanations, and provider-specific setup steps. The same setup guide is included in connector readiness, connector API responses, and Daily OS connector readiness cards so setup blockers are visible before an automation or agent write path depends on them. Connector account/action lookups in the UI and API are workspace scoped. Connector API responses include setup readiness and durable permission grants; `POST /api/v1/workspaces/:workspace_id/connectors/:id/agent_grants` grants an agent a connector write action without storing secrets.

## Settings And Permission UX

Settings now acts as the workspace safety posture surface for provider routes, credential pools, tool policies, permission presets, tool bundle presets, and token spend guardrails. Operators can see reusable permission levels such as observe, draft, approve-writes, and trusted automation alongside the policy bundles that grant concrete tools.

Token spend guardrails can be created from Settings for the whole workspace or an individual agent, scoped by usage category and daily/weekly/monthly/total period. Active budgets are shown with current token usage, warning/exceeded state, and agent scope so the "this agent may spend tokens" permission is visible next to connector and tool permissions.

The core control surfaces tolerate malformed workspace query parameters and fall back to the selected workspace instead of crashing. Regression coverage includes Mission, Run Index, Agent Directory, Memory Studio, Knowledge Node Detail, Graph Workbench, Runtime Operations, Settings, Tools, and Automations.

## Daily OS Starter Agent Packs

Agent Studio includes import buttons for the bundled starter pack catalog. V4 seeds a Daily OS roster:

- `daily-chief-of-staff`: coordinator for briefings, meeting prep, inbox triage, reminders, and room handoffs.
- `inbox-triage`: message classification, reply drafts, task extraction, and follow-up reminders.
- `research-watch`: recurring research monitoring with source verification and durable notes.
- `content-drafter`: drafts social posts, outlines, newsletters, and media prompts from approved context.
- `meeting-prep`: agendas, stakeholder context, and follow-up drafts from calendar/email/notes.

Starter packs preserve productization metadata during import/export in `capability_profile`: `connector_requirements`, `automation_recipes`, `room_defaults`, `task_pack`, `content_channels`, and `delivery_targets`. The public catalog endpoint is `GET /api/v1/agents/starter_packs`, and all bundled packs are checked by the doctor/startup validation path.

Agent Studio also includes a one-click Daily OS setup flow. It is idempotent: it reuses the `daily-os` room, existing starter agents, existing room members, prepared connector accounts, the pending Telegram binding, existing recipe automations, and Daily OS budget guardrails when present. On a fresh workspace it imports the five Daily OS agents, adds them to the room with pack-defined mention handles, prepares connector accounts for the required providers, creates approval-required connector grants for the agents' required write actions, creates a pending Telegram capture binding, schedules the core daily/weekly automation recipes, and creates one workspace monthly token budget plus daily token budgets for each starter agent. The setup result includes connector readiness cards with credential refs, grant counts, missing env/config findings, and provider setup guidance, plus automation readiness cards that show which recipes are blocked by missing connector accounts or secrets before they run.

## Skill Hub Import Flow

Skill imports are scanned before activation:

- Local path, raw markdown, and GitHub repo/path/ref sources are supported.
- `SKILL.md` is the richest format. Compatible instruction imports are also supported from `AGENTS.md`, `CLAUDE.md`, and `README.md`.
- File count, total bytes, executable files, network hints, secret-looking values, and unknown tools are recorded.
- Approval installs the skill with provenance back to the import record and file manifest.

The Tools and Protocols UI can scan raw `SKILL.md` content, local directories, and GitHub repo/path/ref imports, show import warnings, and approve or reject imports. Compatible instruction-file imports are marked with an informational warning so operators can distinguish them from native Hydra/Hermes `SKILL.md` packages. Imports are workspace scoped and approval installs the imported skill as a durable skill record.

## Automation Recipes

The Automations UI includes a ready-made recipe catalog for everyday agent workflows:

- daily briefings
- research watches
- weekly research digests
- content drafts
- weekly content pipelines
- meeting prep
- post-meeting follow-ups
- inbox triage
- follow-up reminders
- reminders
- social monitoring

Recipes create normal durable automations with selected agent, optional room target, timezone, required connector list, and permission preset metadata. They are intentionally templates, not a separate runtime concept.

Automation readiness is computed from each automation's `metadata.required_connectors` and the workspace connector accounts. Missing required connector accounts and hard connector setup failures such as missing env refs, missing secret env values, inactive accounts, or missing required config mark the automation as `blocked`. Recommended setup gaps mark it as `setup_pending`. Readiness is exposed in the Automations UI and API, included in the `needs_attention` filter, and hard blockers fail closed before an automation creates a runtime run.

## Browser Worker

Browser tools now call `HydraAgent.Browser`.

- If `HYDRA_BROWSER_WORKER_URL` is set, actions are sent to the Playwright worker.
- In production, action requests fail closed unless `HYDRA_BROWSER_WORKER_TOKEN` is configured.
- The worker limits request body size, action timeout, session count, session idle lifetime, and screenshot payload size through `HYDRA_BROWSER_WORKER_*` environment settings.
- If no worker is configured, actions are recorded as browser sessions/artifacts when workspace context is present.
- Navigation supports a host allowlist through runtime context.
- Worker results update the durable browser session with current URL, worker session id, artifacts, and last error state.
