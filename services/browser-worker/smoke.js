"use strict";

const assert = require("node:assert/strict");

const baseUrl = process.env.HYDRA_BROWSER_SMOKE_URL || "http://127.0.0.1:4100";

async function request(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, options);
  const body = await response.json();
  return { response, body };
}

async function action(payload) {
  return request("/actions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}

async function main() {
  const health = await request("/health");
  assert.equal(health.response.status, 200);
  assert.equal(health.body.status, "ok");
  assert.equal(health.body.egress_proxy, "dns_pinned");

  const blocked = await action({ action: "navigate", input: { url: "http://127.0.0.1" } });
  assert.equal(blocked.response.status, 403);
  assert.equal(blocked.body.error, "private_network_blocked");

  const mappedBlocked = await action({
    action: "navigate",
    input: { url: "http://[::ffff:7f00:1]" },
  });
  assert.equal(mappedBlocked.response.status, 403);
  assert.equal(mappedBlocked.body.error, "private_network_blocked");

  const unsupported = await action({ action: "evaluate", input: {} });
  assert.equal(unsupported.response.status, 400);
  assert.equal(unsupported.body.error, "unsupported_browser_action");
  const healthAfterRejectedActions = await request("/health");
  assert.equal(healthAfterRejectedActions.body.sessions, health.body.sessions);

  const context = { workspace_id: 1, run_id: 1, agent_id: 1 };
  const navigation = await action({
    action: "navigate",
    input: { url: "https://example.com" },
    context,
  });
  assert.equal(navigation.response.status, 200);
  assert.match(navigation.body.worker_session_id, /^bw-/);

  const extraction = await action({
    action: "extract",
    input: { selector: "body" },
    context: { ...context, browser_session_id: 12345 },
  });
  assert.equal(extraction.response.status, 200);
  assert.equal(extraction.body.worker_session_id, navigation.body.worker_session_id);
  assert.match(extraction.body.text, /Example Domain/i);

  const crossWorkspace = await action({
    action: "extract",
    input: { selector: "body" },
    context: {
      workspace_id: 2,
      run_id: 2,
      agent_id: 2,
      worker_session_id: navigation.body.worker_session_id,
    },
  });
  assert.equal(crossWorkspace.response.status, 404);
  assert.equal(crossWorkspace.body.error, "browser_session_not_found");

  const closed = await request(`/sessions/${encodeURIComponent(navigation.body.worker_session_id)}`, {
    method: "DELETE",
  });
  assert.equal(closed.response.status, 200);

  console.log("browser worker smoke test passed");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
