# SimLab research providers

SimLab fails closed: it sends no research traffic until an operator explicitly enables a provider. Only planner-generated `safe_query` values leave the workspace. Raw study questions, local notes, uploads, and private identifiers are not included.

Retrieval and model generation are intentionally separate:

- A web-search provider returns attributable URLs and excerpts. These become unreviewed `external_research` candidates.
- A model provider may synthesize or classify supplied material. Unsourced output must remain an `assumption` until evidence is linked.

## Tavily advanced web search

Tavily is the first-class agent-oriented web-search adapter. Set:

```sh
export TAVILY_API_KEY="tvly-..."
```

Hydra uses `POST https://api.tavily.com/search` with bearer authentication and these bounded defaults:

```text
search_depth=advanced
chunks_per_source=3
max_results=5
include_answer=false
include_raw_content=false
include_images=false
auto_parameters=false
```

Recent-news lanes use Tavily's `news` topic; other lanes use `general`. Hydra accepts only HTTPS result URLs, stores Tavily's ranked content as a reviewable excerpt, and maps the relevance score into a cautious reliability band. A missing key, authentication error, rate limit, invalid payload, or empty response fails the lane without inventing evidence.

The endpoint, credential environment-variable name, and timeout can be overridden through `config :hydra_agent, :sim_lab_tavily`.

## Local Codex CLI test mode

The local Codex bridge is a development aid, not a production research provider. Enable it only in a non-production environment:

```sh
export HYDRA_SIM_CODEX_CLI_TESTING=1
mix phx.server
```

The CLI must already be installed and authenticated. Hydra invokes it without a shell, closes stdin, ignores personal Codex plugins and MCP configuration, uses an ephemeral session in a temporary directory, enforces a read-only sandbox, caps process output, and applies a two-minute timeout. It batches all research lanes into one CLI call and sends only their abstracted queries.

Codex is instructed to generate cautious, falsifiable test hypotheses—not to claim web research. Hydra validates the JSON response, requires one result for every lane, rejects malformed or oversized output, and persists accepted text as low-confidence `assumption` evidence with `synthetic_test=true`. It never increments the external-research count.

The local CLI command is disabled in production even if the environment flag is accidentally present. If the command fails or produces no valid evidence, the active context pack is not replaced.

## Generic search endpoint

An operator can also configure a compatible endpoint:

```elixir
config :hydra_agent, :sim_lab_web_search,
  endpoint: System.fetch_env!("SIM_LAB_WEB_SEARCH_ENDPOINT"),
  api_key_env: "SIM_LAB_WEB_SEARCH_API_KEY"
```

The adapter sends a `GET` request containing `q=<safe_query>`, `region`, and `language`. The endpoint returns:

```json
{
  "results": [
    {
      "title": "Source title",
      "url": "https://example.com/source",
      "snippet": "Short evidence candidate extract.",
      "reliability": "high"
    }
  ]
}
```

`reliability` accepts `high`, `medium`, `low`, or `unknown`.

Both Tavily and generic overrides must resolve to public HTTPS endpoints. Hydra
rejects IP literals and mixed public/private DNS answers, pins the validated IP
while preserving the original Host/SNI, and disables redirects, retries,
compression, and automatic body decoding. Provider responses are streamed into
a 1 MB cap before JSON decoding. Queries, result counts, titles, and excerpts
are bounded; malformed or non-HTTPS result URLs are discarded. If an
`api_key_env` is configured but empty, the provider remains unavailable.

## Future model APIs

DeepSeek, Moonshot/Kimi, and Qwen should be implemented behind a model-generation contract rather than pretending they are search engines. A typical production protocol will be:

1. Tavily or another retrieval provider finds and ranks attributable web sources.
2. Hydra fetches or accepts bounded excerpts under workspace policy.
3. A selected model extracts claims, contradictions, personas, and behavior proposals into a validated schema.
4. Persisted evidence keeps the retrieval URL, model/provider identity, protocol version, confidence, and review status.

This boundary lets model providers change without rewriting research planning, evidence storage, or simulations.
