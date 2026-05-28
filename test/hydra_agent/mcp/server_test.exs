defmodule HydraAgent.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias HydraAgent.MCP.Server

  test "validates stdio servers with env refs and command allowlists" do
    changeset =
      Server.changeset(%Server{}, %{
        workspace_id: 1,
        name: "Filesystem MCP",
        slug: "filesystem-mcp",
        transport: "stdio",
        config: %{"command" => ["npx", "-y", "@modelcontextprotocol/server-filesystem"]},
        env_refs: ["MCP_FILESYSTEM_TOKEN"],
        include_tools: ["read_file"],
        exclude_tools: ["write_file"]
      })

    assert changeset.valid?
  end

  test "validates http servers with URL config" do
    changeset =
      Server.changeset(%Server{}, %{
        workspace_id: 1,
        name: "Docs MCP",
        slug: "docs-mcp",
        transport: "http",
        config: %{"url" => "https://mcp.example.com"},
        trust_level: "sandboxed"
      })

    assert changeset.valid?
  end

  test "validates bearer env refs without storing token values" do
    changeset =
      Server.changeset(%Server{}, %{
        workspace_id: 1,
        name: "Docs MCP",
        slug: "docs-mcp-auth",
        transport: "http",
        config: %{"url" => "https://mcp.example.com", "bearer_env" => "MCP_DOCS_TOKEN"},
        env_refs: ["MCP_DOCS_TOKEN"]
      })

    assert changeset.valid?
  end

  test "requires bearer env refs to be declared" do
    changeset =
      Server.changeset(%Server{}, %{
        workspace_id: 1,
        name: "Docs MCP",
        slug: "docs-mcp-auth",
        transport: "http",
        config: %{"url" => "https://mcp.example.com", "bearer_env" => "MCP_DOCS_TOKEN"},
        env_refs: []
      })

    refute changeset.valid?
    assert {"bearer_env must be listed in env_refs", _meta} = changeset.errors[:config]
  end

  test "rejects inline secret-like config keys" do
    changeset =
      Server.changeset(%Server{}, %{
        workspace_id: 1,
        name: "Bad MCP",
        slug: "bad-mcp",
        transport: "http",
        config: %{"url" => "https://mcp.example.com", "api_key" => "secret"}
      })

    refute changeset.valid?

    assert {"must not contain inline secret-like keys; use env_refs: api_key", _meta} =
             changeset.errors[:config]
  end

  test "rejects invalid env refs and overlapping filters" do
    changeset =
      Server.changeset(%Server{}, %{
        workspace_id: 1,
        name: "Bad MCP",
        slug: "bad-mcp",
        transport: "stdio",
        config: %{"command" => ["node", "server.js"]},
        env_refs: ["plain-secret"],
        include_tools: ["read_file"],
        exclude_tools: ["read_file"]
      })

    refute changeset.valid?

    assert {"must contain only environment variable names: plain-secret", _meta} =
             changeset.errors[:env_refs]

    assert {"overlaps include_tools: read_file", _meta} = changeset.errors[:exclude_tools]
  end
end
