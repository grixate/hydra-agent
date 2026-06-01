const http = require("node:http");
const { chromium } = require("playwright");

const port = Number(process.env.PORT || 4100);
const sessions = new Map();

let browserPromise;

function getBrowser() {
  browserPromise ||= chromium.launch({ headless: true });
  return browserPromise;
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks).toString("utf8");
  return body ? JSON.parse(body) : {};
}

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

async function getPage(sessionId) {
  if (sessionId && sessions.has(sessionId)) return sessions.get(sessionId);

  const browser = await getBrowser();
  const context = await browser.newContext();
  const page = await context.newPage();
  const id = sessionId || `bw-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const session = { id, context, page, createdAt: new Date().toISOString() };
  sessions.set(id, session);
  return session;
}

async function execute(payload) {
  const { action, input = {}, context = {} } = payload;
  const session = await getPage(context.browser_session_id || context.worker_session_id);
  const { page } = session;

  if (action === "navigate") {
    await page.goto(input.url, { waitUntil: "domcontentloaded", timeout: input.timeout_ms || 30000 });
  } else if (action === "click") {
    await page.click(input.selector, { timeout: input.timeout_ms || 10000 });
  } else if (action === "type") {
    await page.fill(input.selector, input.text || "", { timeout: input.timeout_ms || 10000 });
  } else if (action === "extract") {
    const selector = input.selector || "body";
    const text = await page.locator(selector).first().innerText({ timeout: input.timeout_ms || 10000 });
    return { worker_session_id: session.id, url: page.url(), title: await page.title(), text };
  } else if (action === "screenshot") {
    const bytes = await page.screenshot({ fullPage: input.full_page !== false });
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
      send(res, 200, { status: "ok", sessions: sessions.size });
      return;
    }

    if (req.method === "POST" && req.url === "/actions") {
      const payload = await readJson(req);
      send(res, 200, await execute(payload));
      return;
    }

    send(res, 404, { error: "not_found" });
  } catch (error) {
    send(res, 500, { error: error.message, stack: process.env.NODE_ENV === "production" ? undefined : error.stack });
  }
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Hydra browser worker listening on ${port}`);
});

process.on("SIGTERM", async () => {
  server.close();
  if (browserPromise) await (await browserPromise).close();
  process.exit(0);
});
