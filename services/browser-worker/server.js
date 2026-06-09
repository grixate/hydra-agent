const http = require("node:http");
const { chromium } = require("playwright");

const port = Number(process.env.PORT || 4100);
const actionToken = process.env.HYDRA_BROWSER_WORKER_TOKEN || "";
const maxSessions = Number(process.env.MAX_SESSIONS || 8);
const sessionIdleMs = Number(process.env.SESSION_IDLE_MS || 15 * 60 * 1000);
const maxBodyBytes = Number(process.env.MAX_BODY_BYTES || 1_000_000);
const maxActionTimeoutMs = Number(process.env.MAX_ACTION_TIMEOUT_MS || 30_000);
const maxScreenshotBytes = Number(process.env.MAX_SCREENSHOT_BYTES || 5_000_000);
const sessions = new Map();

let browserPromise;
let cleanupTimer;

function getBrowser() {
  browserPromise ||= chromium.launch({ headless: true });
  return browserPromise;
}

async function readJson(req) {
  const chunks = [];
  let totalBytes = 0;

  for await (const chunk of req) {
    totalBytes += chunk.length;

    if (totalBytes > maxBodyBytes) {
      const error = new Error("request body too large");
      error.statusCode = 413;
      throw error;
    }

    chunks.push(chunk);
  }

  const body = Buffer.concat(chunks).toString("utf8");

  try {
    return body ? JSON.parse(body) : {};
  } catch (_error) {
    const error = new Error("invalid json body");
    error.statusCode = 400;
    throw error;
  }
}

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function clampTimeout(input, fallbackMs) {
  const requested = Number(input.timeout_ms || fallbackMs);
  return Math.max(1, Math.min(requested, maxActionTimeoutMs));
}

function authorized(req) {
  if (!actionToken) return true;
  return req.headers.authorization === `Bearer ${actionToken}`;
}

async function closeSession(session) {
  sessions.delete(session.id);
  await session.context.close().catch(() => {});
}

async function cleanupIdleSessions() {
  const now = Date.now();

  for (const session of sessions.values()) {
    if (now - session.lastUsedAt > sessionIdleMs) {
      await closeSession(session);
    }
  }
}

async function getPage(sessionId) {
  await cleanupIdleSessions();

  if (sessionId && sessions.has(sessionId)) {
    const session = sessions.get(sessionId);
    session.lastUsedAt = Date.now();
    return session;
  }

  if (sessions.size >= maxSessions) {
    const oldest = [...sessions.values()].sort((left, right) => left.lastUsedAt - right.lastUsedAt)[0];

    if (oldest && Date.now() - oldest.lastUsedAt > sessionIdleMs) {
      await closeSession(oldest);
    }
  }

  if (sessions.size >= maxSessions) {
    const error = new Error("browser session limit reached");
    error.statusCode = 429;
    throw error;
  }

  const browser = await getBrowser();
  const context = await browser.newContext();
  const page = await context.newPage();
  const id = sessionId || `bw-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const session = {
    id,
    context,
    page,
    createdAt: new Date().toISOString(),
    lastUsedAt: Date.now(),
  };
  sessions.set(id, session);
  return session;
}

async function execute(payload) {
  const { action, input = {}, context = {} } = payload;
  const session = await getPage(context.browser_session_id || context.worker_session_id);
  const { page } = session;

  if (action === "navigate") {
    await page.goto(input.url, { waitUntil: "domcontentloaded", timeout: clampTimeout(input, 30000) });
  } else if (action === "click") {
    await page.click(input.selector, { timeout: clampTimeout(input, 10000) });
  } else if (action === "type") {
    await page.fill(input.selector, input.text || "", { timeout: clampTimeout(input, 10000) });
  } else if (action === "extract") {
    const selector = input.selector || "body";
    const text = await page.locator(selector).first().innerText({ timeout: clampTimeout(input, 10000) });
    return { worker_session_id: session.id, url: page.url(), title: await page.title(), text };
  } else if (action === "screenshot") {
    const bytes = await page.screenshot({ fullPage: input.full_page !== false });

    if (bytes.length > maxScreenshotBytes) {
      const error = new Error("screenshot exceeds maximum size");
      error.statusCode = 413;
      throw error;
    }

    return {
      worker_session_id: session.id,
      url: page.url(),
      title: await page.title(),
      screenshot_base64: bytes.toString("base64"),
      content_type: "image/png",
    };
  } else {
    throw new Error(`unsupported action: ${action}`);
  }

  return { worker_session_id: session.id, url: page.url(), title: await page.title() };
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      send(res, 200, {
        status: "ok",
        sessions: sessions.size,
        limits: {
          max_sessions: maxSessions,
          max_body_bytes: maxBodyBytes,
          max_action_timeout_ms: maxActionTimeoutMs,
        },
      });
      return;
    }

    if (req.method === "POST" && req.url === "/actions") {
      if (!authorized(req)) {
        send(res, 401, { error: "unauthorized" });
        return;
      }

      const payload = await readJson(req);
      send(res, 200, await execute(payload));
      return;
    }

    send(res, 404, { error: "not_found" });
  } catch (error) {
    const status = error.statusCode || 500;
    send(res, status, {
      error: error.message,
      stack: process.env.NODE_ENV === "production" ? undefined : error.stack,
    });
  }
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Hydra browser worker listening on ${port}`);
});

cleanupTimer = setInterval(() => {
  cleanupIdleSessions().catch((error) => {
    console.error("browser worker cleanup failed", error);
  });
}, Math.min(sessionIdleMs, 60_000));

async function shutdown() {
  if (cleanupTimer) clearInterval(cleanupTimer);
  server.close();
  for (const session of sessions.values()) await closeSession(session);
  if (browserPromise) await (await browserPromise).close();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
