# Client Apps

Hydra's core product is the runtime, API, CLI, and chat adapters. Browser UIs
should be separate client apps that consume the API rather than plugins mounted
inside the Phoenix application.

This keeps the runtime neutral and lets multiple clients coexist:

- `bin/hydra` for native operator workflows
- Telegram or other room channels for chat operations
- a first-party management UI
- design, coding, mobile, or ops clients
- plugin companion surfaces launched by clients

## Contract

Client apps should start from the workspace plugin contract:

```sh
bin/hydra plugins client-contract --workspace WORKSPACE_ID
```

The contract reports installed plugins, capability summaries, enabled client
surfaces, requested API scopes, config schemas, compatibility metadata, and
dependencies.

Client apps should use this contract to render plugin-aware controls without
assuming which runtime plugins are installed. Plugins may add runtime
capabilities and optional launchable surfaces; they should not be required for
the management UI itself to exist.

Client apps can read and update non-secret plugin configuration through:

```text
GET /api/v1/workspaces/:workspace_id/plugins/:id/config
PUT /api/v1/workspaces/:workspace_id/plugins/:id/config
```

The configuration endpoint validates the submitted object against the plugin's
`config_schema` and rejects secret-looking keys. Client apps should render
secret fields as environment-variable setup instructions instead of storing
secret values.

## UI Surfaces

Plugin `client_surfaces` are launch specs, not Hydra-owned routes. The current
surface kind is `external_url`:

```json
{
  "name": "design-studio",
  "kind": "external_url",
  "surface": "workspace",
  "required_scopes": ["workspaces:read", "runs:read"],
  "entrypoint": {
    "type": "external_url",
    "url_env": "HYDRA_DESIGN_STUDIO_URL"
  }
}
```

The core validates and exposes this metadata. A client app decides whether to
link, open, embed, or ignore the surface.
