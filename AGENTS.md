# Hydra Agent Instructions

This repository is a Phoenix/Elixir application for a self-hosted agent runtime.

## Direction

- Keep the core product neutral: workspaces, agents, runs, policies, providers, memory, knowledge graph, skills, MCP, and tools.
- Do not reintroduce product-management concepts such as requirements, insights, strategies, boards, or project-specific agent personas into the runtime core.
- If a domain-specific workflow is useful, make it an agent pack or optional template.
- Security defaults must fail closed. Agents start read-only unless policy grants more.
- Prefer durable, inspectable runtime state over hidden in-memory orchestration.

## Development

- Use `mix precommit` before considering changes done.
- Use `Req` for HTTP clients.
- Avoid storing raw secrets in the database. Prefer environment-variable references for early V1.
- Keep migrations and schemas workspace-scoped unless a table is truly global.
