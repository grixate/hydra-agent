"use strict";

const crypto = require("node:crypto");
const dns = require("node:dns").promises;
const http = require("node:http");
const net = require("node:net");
const ipaddr = require("ipaddr.js");
const { chromium } = require("playwright");

class HttpError extends Error {
  constructor(status, code, message = code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function positiveIntegerEnv(name, fallback, maximum = Number.MAX_SAFE_INTEGER) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;

  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new Error(`${name} must be a positive integer no greater than ${maximum}`);
  }
  return value;
}

function booleanEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (["true", "1"].includes(raw)) return true;
  if (["false", "0"].includes(raw)) return false;
  throw new Error(`${name} must be true, false, 1, or 0`);
}

const port = positiveIntegerEnv("PORT", 4100, 65535);
const maxBodyBytes = positiveIntegerEnv("HYDRA_BROWSER_MAX_BODY_BYTES", 1_000_000, 10_000_000);
const maxSessions = positiveIntegerEnv("HYDRA_BROWSER_MAX_SESSIONS", 32, 1_000);
const maxConcurrentActions = positiveIntegerEnv("HYDRA_BROWSER_MAX_CONCURRENT_ACTIONS", 8, 100);
const sessionTtlMs = positiveIntegerEnv("HYDRA_BROWSER_SESSION_TTL_MS", 30 * 60_000, 24 * 60 * 60_000);
const maxExtractBytes = positiveIntegerEnv("HYDRA_BROWSER_MAX_EXTRACT_BYTES", 250_000, 2_000_000);
const maxScreenshotBytes = positiveIntegerEnv("HYDRA_BROWSER_MAX_SCREENSHOT_BYTES", 5_000_000, 20_000_000);
const maxTypeBytes = positiveIntegerEnv("HYDRA_BROWSER_MAX_TYPE_BYTES", 100_000, 1_000_000);
const maxProxyConnections = positiveIntegerEnv("HYDRA_BROWSER_MAX_PROXY_CONNECTIONS", 256, 2_000);
const dnsTimeoutMs = positiveIntegerEnv("HYDRA_BROWSER_DNS_TIMEOUT_MS", 5_000, 30_000);
const allowPrivateNetworks = booleanEnv("HYDRA_BROWSER_ALLOW_PRIVATE_NETWORKS", false);
const chromiumSandbox = booleanEnv("HYDRA_BROWSER_CHROMIUM_SANDBOX", false);

const allowedHosts = (process.env.HYDRA_BROWSER_ALLOWED_HOSTS || "")
  .split(",")
  .map((value) => value.trim().toLowerCase())
  .filter(Boolean);

const allowedPortsRaw = (process.env.HYDRA_BROWSER_ALLOWED_PORTS || "80,443").trim();
const allowAnyPort = allowedPortsRaw === "*";
const allowedPorts = new Set(
  allowAnyPort
    ? []
    : allowedPortsRaw
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean),
);

if (
  !allowAnyPort &&
  [...allowedPorts].some(
    (value) => !/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 65_535,
  )
) {
  throw new Error("HYDRA_BROWSER_ALLOWED_PORTS must contain ports from 1 through 65535 or *");
}

const sessions = new Map();
const sessionsByContext = new Map();
const recentProxyPolicyBlocks = new Map();
const proxyPolicyHeader = "x-hydra-browser-policy";
let activeActions = 0;
let browserInstance = null;
let browserPromise = null;
let pinnedProxyInstance = null;
let pinnedProxyPromise = null;
let shuttingDown = false;
let sessionCreationTail = Promise.resolve();

function normalizeHost(hostname) {
  return hostname.toLowerCase().replace(/^\[/, "").replace(/\]$/, "").replace(/\.$/, "");
}

function isPrivateAddress(address) {
  try {
    // Only ordinary global unicast addresses may leave the worker. This also
    // rejects IPv4-mapped IPv6, NAT64, 6to4, Teredo, documentation, benchmark,
    // link-local, multicast, and otherwise reserved ranges.
    return ipaddr.parse(address.split("%")[0]).range() !== "unicast";
  } catch (_error) {
    return true;
  }
}

function hostMatchesAllowlist(host) {
  if (allowedHosts.length === 0) return true;

  return allowedHosts.some((allowed) => {
    if (allowed === host) return true;
    if (allowed.startsWith("*.")) {
      const suffix = allowed.slice(1);
      return host.endsWith(suffix) && host.length > suffix.length;
    }
    return false;
  });
}

function privateHostname(host) {
  return (
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local") ||
    host.endsWith(".internal") ||
    host.endsWith(".home.arpa")
  );
}

function withDeadline(promise, timeoutMs, code) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new HttpError(504, code)), timeoutMs);
    timer.unref?.();
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function resolvePinnedHost(
  host,
  { lookup = dns.lookup, allowPrivate = allowPrivateNetworks } = {},
) {
  if (!allowPrivate && privateHostname(host)) {
    throw new HttpError(403, "private_network_blocked");
  }

  const literalFamily = net.isIP(host);
  let answers;
  if (literalFamily) {
    answers = [{ address: host, family: literalFamily }];
  } else {
    try {
      answers = await withDeadline(
        Promise.resolve(lookup(host, { all: true, verbatim: true })),
        dnsTimeoutMs,
        "browser_dns_resolution_timeout",
      );
    } catch (error) {
      if (error instanceof HttpError) throw error;
      throw new HttpError(502, "browser_dns_resolution_failed");
    }
  }

  if (!Array.isArray(answers) || answers.length === 0) {
    throw new HttpError(502, "browser_dns_resolution_failed");
  }
  if (
    answers.some(
      ({ address, family }) =>
        ![4, 6].includes(Number(family)) ||
        net.isIP(address) !== Number(family) ||
        (!allowPrivate && isPrivateAddress(address)),
    )
  ) {
    throw new HttpError(403, "private_network_blocked");
  }

  // Prefer IPv4 because many container hosts have no routed IPv6. The chosen
  // numeric address is returned to the proxy and never resolved a second time.
  const selected = answers.find(({ family }) => Number(family) === 4) || answers[0];
  return { address: selected.address, family: Number(selected.family) };
}

function validateHostAndPort(host, effectivePort) {
  if (!host || !hostMatchesAllowlist(host)) {
    throw new HttpError(403, "browser_host_not_allowed");
  }
  if (!/^\d+$/.test(effectivePort) || Number(effectivePort) < 1 || Number(effectivePort) > 65_535) {
    throw new HttpError(400, "invalid_browser_url");
  }
  if (!allowAnyPort && !allowedPorts.has(effectivePort)) {
    throw new HttpError(403, "browser_port_not_allowed");
  }
  if (
    !allowPrivateNetworks &&
    (privateHostname(host) || (net.isIP(host) && isPrivateAddress(host)))
  ) {
    throw new HttpError(403, "private_network_blocked");
  }
}

function assertAllowedUrl(value, protocols = ["http:", "https:"]) {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value) > 8_192) {
    throw new HttpError(400, "invalid_browser_url");
  }

  let url;
  try {
    url = new URL(value);
  } catch (_error) {
    throw new HttpError(400, "invalid_browser_url");
  }

  if (!protocols.includes(url.protocol) || url.username || url.password) {
    throw new HttpError(400, "invalid_browser_url");
  }

  const host = normalizeHost(url.hostname);
  const effectivePort = url.port || (url.protocol === "http:" || url.protocol === "ws:" ? "80" : "443");
  validateHostAndPort(host, effectivePort);

  return { url, host, port: Number(effectivePort) };
}

async function resolvePinnedUrl(
  value,
  protocols = ["http:", "https:"],
  resolverOptions = {},
) {
  const allowed = assertAllowedUrl(value, protocols);
  const { host } = allowed;
  const pinned = await resolvePinnedHost(host, resolverOptions);
  return { ...allowed, ...pinned };
}

async function assertPublicUrl(value, protocols = ["http:", "https:"]) {
  return (await resolvePinnedUrl(value, protocols)).url;
}

function proxyError(error) {
  return error instanceof HttpError
    ? { status: error.status, code: error.code }
    : { status: 502, code: "browser_proxy_upstream_failed" };
}

function recordProxyPolicyBlock(host, error) {
  if (!host || !(error instanceof HttpError)) return;
  if (recentProxyPolicyBlocks.size >= 256) recentProxyPolicyBlocks.clear();
  recentProxyPolicyBlocks.set(host, {
    code: error.code,
    status: error.status,
    recordedAt: Date.now(),
  });
}

function consumeProxyPolicyBlock(value) {
  let host;
  try {
    host = normalizeHost(new URL(value).hostname);
  } catch (_error) {
    return null;
  }
  const block = recentProxyPolicyBlocks.get(host);
  if (!block) return null;
  recentProxyPolicyBlocks.delete(host);
  return Date.now() - block.recordedAt <= 10_000 ? block : null;
}

async function throwIfProxyPolicyResponse(response) {
  if (!response) return;
  if (new URL(response.url()).protocol !== "http:") return;
  const code = await response.headerValue(proxyPolicyHeader);
  if (code) throw new HttpError(response.status(), code);
}

function sendProxyError(res, error) {
  const { status, code } = proxyError(error);
  if (res.headersSent) {
    res.destroy(error instanceof Error ? error : undefined);
    return;
  }
  const body = JSON.stringify({ error: code });
  const headers = {
    "cache-control": "no-store",
    connection: "close",
    "content-length": Buffer.byteLength(body),
    "content-type": "application/json; charset=utf-8",
  };
  if (error instanceof HttpError) headers[proxyPolicyHeader] = code;
  res.writeHead(status, headers);
  res.end(body);
}

function sendProxySocketError(socket, error) {
  if (socket.destroyed) return;
  const { status, code } = proxyError(error);
  const body = JSON.stringify({ error: code });
  socket.end(
    `HTTP/1.1 ${status} Proxy Error\r\n` +
      "Connection: close\r\n" +
      "Cache-Control: no-store\r\n" +
      "Content-Type: application/json; charset=utf-8\r\n" +
      `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`,
  );
}

function parseConnectAuthority(authority) {
  if (
    typeof authority !== "string" ||
    authority.length === 0 ||
    Buffer.byteLength(authority) > 1_024 ||
    /[\s/?#@]/.test(authority)
  ) {
    throw new HttpError(400, "invalid_browser_url");
  }

  let hostToken;
  let effectivePort;
  if (authority.startsWith("[")) {
    const closingBracket = authority.indexOf("]");
    if (closingBracket <= 1 || authority[closingBracket + 1] !== ":") {
      throw new HttpError(400, "invalid_browser_url");
    }
    hostToken = authority.slice(0, closingBracket + 1);
    effectivePort = authority.slice(closingBracket + 2);
  } else {
    const separator = authority.lastIndexOf(":");
    if (separator <= 0 || authority.slice(0, separator).includes(":")) {
      throw new HttpError(400, "invalid_browser_url");
    }
    hostToken = authority.slice(0, separator);
    effectivePort = authority.slice(separator + 1);
  }

  let parsedHost;
  try {
    parsedHost = new URL(`http://${hostToken}/`);
  } catch (_error) {
    throw new HttpError(400, "invalid_browser_url");
  }
  if (
    parsedHost.username ||
    parsedHost.password ||
    parsedHost.port ||
    parsedHost.pathname !== "/" ||
    parsedHost.search ||
    parsedHost.hash
  ) {
    throw new HttpError(400, "invalid_browser_url");
  }

  const host = normalizeHost(parsedHost.hostname);
  validateHostAndPort(host, effectivePort);
  return { host, port: Number(effectivePort) };
}

async function resolvePinnedAuthority(authority, resolverOptions = {}) {
  const target = parseConnectAuthority(authority);
  return { ...target, ...(await resolvePinnedHost(target.host, resolverOptions)) };
}

function proxyRequestUrl(req, protocols) {
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(req.url || "")) return req.url;
  if (!req.headers.host || !protocols.includes("ws:")) {
    throw new HttpError(400, "invalid_browser_url");
  }
  return `ws://${req.headers.host}${req.url || "/"}`;
}

function openPinnedSocket(target, connectImpl) {
  return connectImpl({
    host: target.address,
    port: target.port,
    family: target.family,
  });
}

function websocketRequestHead(req, target) {
  const path = `${target.url.pathname || "/"}${target.url.search}`;
  const lines = [`${req.method} ${path} HTTP/${req.httpVersion}`];
  let sawHost = false;
  for (let index = 0; index < req.rawHeaders.length; index += 2) {
    const name = req.rawHeaders[index];
    const lower = name.toLowerCase();
    if (lower === "proxy-authorization" || lower === "proxy-connection") continue;
    if (lower === "host") {
      lines.push(`${name}: ${target.url.host}`);
      sawHost = true;
    } else {
      lines.push(`${name}: ${req.rawHeaders[index + 1]}`);
    }
  }
  if (!sawHost) lines.push(`Host: ${target.url.host}`);
  return `${lines.join("\r\n")}\r\n\r\n`;
}

function createPinnedProxy({ lookup = dns.lookup, httpRequest = http.request, connect = net.connect } = {}) {
  const resolverOptions = { lookup, allowPrivate: allowPrivateNetworks };
  const trackedSockets = new Set();
  const trackSocket = (socket) => {
    if (!socket || trackedSockets.has(socket)) return socket;
    trackedSockets.add(socket);
    socket.once("close", () => trackedSockets.delete(socket));
    return socket;
  };

  const proxy = http.createServer(async (clientReq, clientRes) => {
    let upstream;
    let policyHost;
    let cancelled = clientReq.aborted || clientRes.destroyed;
    const cancel = () => {
      cancelled = true;
      upstream?.destroy();
    };
    clientReq.once("aborted", cancel);
    clientReq.socket.once("end", cancel);
    clientReq.socket.once("close", cancel);
    clientRes.once("close", () => {
      if (!clientRes.writableEnded) cancel();
    });

    try {
      const allowed = assertAllowedUrl(proxyRequestUrl(clientReq, ["http:"]), ["http:"]);
      policyHost = allowed.host;
      const target = { ...allowed, ...(await resolvePinnedHost(allowed.host, resolverOptions)) };
      if (cancelled || clientReq.aborted || clientReq.socket.destroyed || clientRes.destroyed) return;

      const headers = { ...clientReq.headers, host: target.url.host, connection: "close" };
      delete headers["proxy-authorization"];
      delete headers["proxy-connection"];

      upstream = httpRequest(
        {
          protocol: "http:",
          hostname: target.address,
          family: target.family,
          port: target.port,
          method: clientReq.method,
          path: `${target.url.pathname || "/"}${target.url.search}`,
          headers,
          agent: false,
        },
        (upstreamRes) => {
          if (cancelled || clientRes.destroyed) {
            upstreamRes.destroy();
            return;
          }
          const responseHeaders = { ...upstreamRes.headers };
          delete responseHeaders[proxyPolicyHeader];
          if (!clientRes.headersSent) {
            clientRes.writeHead(upstreamRes.statusCode || 502, responseHeaders);
          }
          upstreamRes.pipe(clientRes);
        },
      );
      upstream.on("socket", trackSocket);
      upstream.setTimeout?.(35_000, () => upstream.destroy(new Error("proxy upstream timeout")));
      upstream.on("error", (error) => {
        if (!cancelled) sendProxyError(clientRes, error);
      });
      if (cancelled || clientRes.destroyed) upstream.destroy();
      else clientReq.pipe(upstream);
    } catch (error) {
      upstream?.destroy();
      if (!cancelled && !clientRes.destroyed) {
        recordProxyPolicyBlock(policyHost, error);
        sendProxyError(clientRes, error);
      }
    }
  });

  proxy.on("connect", (req, clientSocket, head) => {
    void (async () => {
      let upstream;
      let connected = false;
      let policyHost;
      let cancelled = clientSocket.destroyed;
      const cancel = () => {
        cancelled = true;
        upstream?.destroy();
      };
      clientSocket.once("error", cancel);
      clientSocket.once("end", cancel);
      clientSocket.once("close", cancel);

      try {
        const allowed = parseConnectAuthority(req.url);
        policyHost = allowed.host;
        const target = { ...allowed, ...(await resolvePinnedHost(allowed.host, resolverOptions)) };
        if (cancelled || clientSocket.destroyed) return;
        upstream = trackSocket(openPinnedSocket(target, connect));
        upstream.setTimeout?.(10_000, () => upstream.destroy(new Error("proxy connect timeout")));
        upstream.once("connect", () => {
          if (cancelled || clientSocket.destroyed) {
            upstream.destroy();
            return;
          }
          connected = true;
          upstream.setTimeout?.(0);
          clientSocket.write("HTTP/1.1 200 Connection Established\r\nProxy-Agent: hydra-pinned\r\n\r\n");
          if (head.length > 0) upstream.write(head);
          clientSocket.pipe(upstream);
          upstream.pipe(clientSocket);
        });
        upstream.on("error", (error) => {
          if (cancelled) return;
          if (connected) clientSocket.destroy(error);
          else sendProxySocketError(clientSocket, error);
        });
      } catch (error) {
        upstream?.destroy();
        if (!cancelled && !clientSocket.destroyed) {
          recordProxyPolicyBlock(policyHost, error);
          sendProxySocketError(clientSocket, error);
        }
      }
    })();
  });

  proxy.on("upgrade", (req, clientSocket, head) => {
    void (async () => {
      let upstream;
      let connected = false;
      let policyHost;
      let cancelled = clientSocket.destroyed;
      const cancel = () => {
        cancelled = true;
        upstream?.destroy();
      };
      clientSocket.once("error", cancel);
      clientSocket.once("end", cancel);
      clientSocket.once("close", cancel);

      try {
        if (req.method !== "GET" || String(req.headers.upgrade).toLowerCase() !== "websocket") {
          throw new HttpError(400, "invalid_browser_websocket_upgrade");
        }
        const allowed = assertAllowedUrl(
          proxyRequestUrl(req, ["http:", "ws:"]),
          ["http:", "ws:"],
        );
        policyHost = allowed.host;
        const target = { ...allowed, ...(await resolvePinnedHost(allowed.host, resolverOptions)) };
        if (cancelled || clientSocket.destroyed) return;
        upstream = trackSocket(openPinnedSocket(target, connect));
        upstream.setTimeout?.(10_000, () => upstream.destroy(new Error("proxy connect timeout")));
        upstream.once("connect", () => {
          if (cancelled || clientSocket.destroyed) {
            upstream.destroy();
            return;
          }
          connected = true;
          upstream.setTimeout?.(0);
          upstream.write(websocketRequestHead(req, target));
          if (head.length > 0) upstream.write(head);
          clientSocket.pipe(upstream);
          upstream.pipe(clientSocket);
        });
        upstream.on("error", (error) => {
          if (cancelled) return;
          if (connected) clientSocket.destroy(error);
          else sendProxySocketError(clientSocket, error);
        });
      } catch (error) {
        upstream?.destroy();
        if (!cancelled && !clientSocket.destroyed) {
          recordProxyPolicyBlock(policyHost, error);
          sendProxySocketError(clientSocket, error);
        }
      }
    })();
  });

  proxy.on("connection", trackSocket);
  proxy.destroyTrackedSockets = () => {
    for (const socket of trackedSockets) socket.destroy();
    trackedSockets.clear();
  };
  proxy.trackedSocketCount = () => trackedSockets.size;
  proxy.headersTimeout = 10_000;
  proxy.requestTimeout = 35_000;
  proxy.keepAliveTimeout = 5_000;
  proxy.maxHeadersCount = 64;
  proxy.maxRequestsPerSocket = 100;
  proxy.maxConnections = maxProxyConnections;
  return proxy;
}

async function getPinnedProxy() {
  if (pinnedProxyInstance?.listening) {
    const { port: proxyPort } = pinnedProxyInstance.address();
    return { server: pinnedProxyInstance, url: `http://127.0.0.1:${proxyPort}` };
  }
  if (pinnedProxyPromise) return pinnedProxyPromise;

  pinnedProxyPromise = new Promise((resolve, reject) => {
    const proxy = createPinnedProxy();
    const fail = (error) => {
      pinnedProxyInstance = null;
      pinnedProxyPromise = null;
      reject(error);
    };
    proxy.once("error", fail);
    proxy.listen(0, "127.0.0.1", () => {
      proxy.off("error", fail);
      proxy.on("error", (error) => console.error("browser egress proxy failed", error));
      proxy.once("close", () => {
        if (pinnedProxyInstance === proxy) pinnedProxyInstance = null;
        pinnedProxyPromise = null;
      });
      pinnedProxyInstance = proxy;
      const { port: proxyPort } = proxy.address();
      resolve({ server: proxy, url: `http://127.0.0.1:${proxyPort}` });
    });
  });
  return pinnedProxyPromise;
}

function boundedTimeout(value, fallback, maximum) {
  const parsed = Number(value ?? fallback);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(Math.floor(parsed), maximum);
}

async function getBrowser() {
  if (browserInstance?.isConnected() && pinnedProxyInstance?.listening) return browserInstance;
  if (browserInstance?.isConnected()) {
    await browserInstance.close();
    browserInstance = null;
    browserPromise = null;
  }
  if (browserPromise) return browserPromise;

  browserPromise = getPinnedProxy()
    .then(({ url: proxyUrl }) =>
      chromium.launch({
        headless: true,
        chromiumSandbox,
        proxy: { server: proxyUrl, bypass: "<-loopback>" },
        args: [
          "--disable-quic",
          "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
        ],
      }),
    )
    .then((browser) => {
      browserInstance = browser;
      browser.on("disconnected", () => {
        if (browserInstance === browser) {
          browserInstance = null;
          browserPromise = null;
        }
      });
      return browser;
    })
    .catch((error) => {
      browserInstance = null;
      browserPromise = null;
      throw error;
    });

  return browserPromise;
}

function contextSignatures(context) {
  if (context.workspace_id === undefined || context.workspace_id === null) return [];

  const workspace = String(context.workspace_id);
  const signatures = [];
  if (context.browser_session_id !== undefined && context.browser_session_id !== null) {
    signatures.push(`${workspace}:database-session:${String(context.browser_session_id).slice(0, 160)}`);
  }
  if (context.run_id !== undefined && context.run_id !== null) {
    signatures.push(
      `${workspace}:run:${String(context.run_id)}:agent:${String(context.agent_id ?? "none")}`,
    );
  }
  return signatures;
}

function requestedWorkerSessionId(context) {
  const value = context.worker_session_id;
  return value === undefined || value === null || value === "" ? null : String(value).slice(0, 160);
}

function indexSessionSignatures(session, signatures) {
  for (const signature of signatures) {
    session.contextSignatures.add(signature);
    sessionsByContext.set(signature, session.id);
  }
}

async function closeSession(id) {
  const session = sessions.get(id);
  if (!session) return false;

  sessions.delete(id);
  for (const signature of session.contextSignatures) {
    if (sessionsByContext.get(signature) === id) sessionsByContext.delete(signature);
  }

  try {
    await session.context.close();
  } catch (_error) {
    // Closing an already-disconnected browser context is harmless.
  }
  return true;
}

async function cleanupExpiredSessions(now = Date.now()) {
  const expired = [...sessions.values()]
    .filter((session) => now - session.lastUsedAt >= sessionTtlMs || session.page.isClosed())
    .map((session) => session.id);

  await Promise.all(expired.map(closeSession));
  return expired.length;
}

async function configureNetworkPolicy(context) {
  await context.route("**/*", async (route) => {
    const requestUrl = route.request().url();
    try {
      const protocol = new URL(requestUrl).protocol;
      if (["http:", "https:"].includes(protocol)) {
        assertAllowedUrl(requestUrl);
      } else if (!["about:", "blob:", "data:"].includes(protocol)) {
        throw new HttpError(403, "browser_protocol_not_allowed");
      }
      await route.continue();
    } catch (_error) {
      await route.abort("blockedbyclient").catch(() => {});
    }
  });

  await context.routeWebSocket("**/*", async (webSocket) => {
    try {
      assertAllowedUrl(webSocket.url(), ["ws:", "wss:"]);
      webSocket.connectToServer();
    } catch (_error) {
      await webSocket.close({ code: 1008, reason: "Network policy blocked this connection" });
    }
  });
}

async function createSession(context) {
  await cleanupExpiredSessions();
  if (sessions.size >= maxSessions) throw new HttpError(503, "browser_session_capacity_reached");

  const browser = await getBrowser();
  const browserContext = await browser.newContext({
    acceptDownloads: false,
    serviceWorkers: "block",
    viewport: { width: 1280, height: 720 },
  });
  browserContext.setDefaultTimeout(10_000);
  browserContext.setDefaultNavigationTimeout(30_000);
  await configureNetworkPolicy(browserContext);

  const page = await browserContext.newPage();
  page.on("dialog", (dialog) => dialog.dismiss().catch(() => {}));

  const signatures = contextSignatures(context);
  const id = `bw-${crypto.randomUUID()}`;
  const now = Date.now();
  const session = {
    id,
    context: browserContext,
    page,
    workspaceId:
      context.workspace_id === undefined || context.workspace_id === null
        ? null
        : String(context.workspace_id),
    contextSignatures: new Set(),
    createdAt: now,
    lastUsedAt: now,
    busy: false,
  };

  sessions.set(id, session);
  indexSessionSignatures(session, signatures);
  browserContext.on("close", () => {
    sessions.delete(id);
    for (const signature of session.contextSignatures) {
      if (sessionsByContext.get(signature) === id) sessionsByContext.delete(signature);
    }
  });
  return session;
}

function findSession(context) {
  const requested = requestedWorkerSessionId(context);
  if (requested && sessions.has(requested)) {
    const session = sessions.get(requested);
    const workspaceId =
      context.workspace_id === undefined || context.workspace_id === null
        ? null
        : String(context.workspace_id);
    if (session.workspaceId !== workspaceId) throw new HttpError(404, "browser_session_not_found");
    indexSessionSignatures(session, contextSignatures(context));
    return session;
  }

  const signatures = contextSignatures(context);
  for (const signature of signatures) {
    const contextualId = sessionsByContext.get(signature);
    if (contextualId && sessions.has(contextualId)) {
      const session = sessions.get(contextualId);
      indexSessionSignatures(session, signatures);
      return session;
    }
  }

  return null;
}

async function getSession(context) {
  const existing = findSession(context);
  if (existing) return existing;

  // Serialize only session creation. This makes the configured capacity exact
  // and prevents simultaneous first actions for one run from leaking contexts.
  let releaseCreation;
  const priorCreation = sessionCreationTail;
  sessionCreationTail = new Promise((resolve) => {
    releaseCreation = resolve;
  });
  await priorCreation;

  try {
    return findSession(context) || (await createSession(context));
  } finally {
    releaseCreation();
  }
}

function requireSelector(value) {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value) > 4_096) {
    throw new HttpError(400, "invalid_browser_selector");
  }
  return value;
}

function truncateUtf8(value, maximumBytes) {
  const encoded = Buffer.from(value, "utf8");
  if (encoded.length <= maximumBytes) return { value, truncated: false };
  return { value: encoded.subarray(0, maximumBytes).toString("utf8"), truncated: true };
}

function validateActionInput(action, input) {
  if (action === "navigate") {
    assertAllowedUrl(input.url);
    return;
  }
  if (action === "click") {
    requireSelector(input.selector);
    return;
  }
  if (action === "type") {
    requireSelector(input.selector);
    const text = input.text ?? "";
    if (typeof text !== "string" || Buffer.byteLength(text) > maxTypeBytes) {
      throw new HttpError(413, "browser_type_input_too_large");
    }
    return;
  }
  if (action === "extract") {
    if (input.selector !== undefined) requireSelector(input.selector);
    return;
  }
  if (action === "screenshot") return;
  throw new HttpError(400, "unsupported_browser_action");
}

async function execute(payload) {
  const { action, input = {}, context = {} } = payload || {};
  if (typeof input !== "object" || input === null || typeof context !== "object" || context === null) {
    throw new HttpError(400, "invalid_browser_payload");
  }
  await validateActionInput(action, input);

  const session = await getSession(context);
  if (session.busy) throw new HttpError(409, "browser_session_busy");
  session.busy = true;
  session.lastUsedAt = Date.now();

  try {
    const { page } = session;
    let result = {};

    if (action === "navigate") {
      try {
        const response = await page.goto(input.url, {
          waitUntil: "domcontentloaded",
          timeout: boundedTimeout(input.timeout_ms, 30_000, 30_000),
        });
        await throwIfProxyPolicyResponse(response);
      } catch (error) {
        if (error instanceof HttpError) {
          consumeProxyPolicyBlock(input.url);
          throw error;
        }
        const block = consumeProxyPolicyBlock(input.url);
        if (block) throw new HttpError(block.status, block.code);
        throw error;
      }
    } else if (action === "click") {
      await page.click(requireSelector(input.selector), {
        timeout: boundedTimeout(input.timeout_ms, 10_000, 20_000),
      });
    } else if (action === "type") {
      const text = input.text ?? "";
      if (typeof text !== "string" || Buffer.byteLength(text) > maxTypeBytes) {
        throw new HttpError(413, "browser_type_input_too_large");
      }
      await page.fill(requireSelector(input.selector), text, {
        timeout: boundedTimeout(input.timeout_ms, 10_000, 20_000),
      });
    } else if (action === "extract") {
      const selector = input.selector === undefined ? "body" : requireSelector(input.selector);
      const text = await page.locator(selector).first().innerText({
        timeout: boundedTimeout(input.timeout_ms, 10_000, 20_000),
      });
      const bounded = truncateUtf8(text, maxExtractBytes);
      result = { text: bounded.value, truncated: bounded.truncated };
    } else if (action === "screenshot") {
      const bytes = await page.screenshot({ fullPage: input.full_page === true });
      if (bytes.length > maxScreenshotBytes) {
        throw new HttpError(413, "browser_screenshot_too_large");
      }
      result = { screenshot_base64: bytes.toString("base64"), content_type: "image/png" };
    } else {
      throw new HttpError(400, "unsupported_browser_action");
    }

    session.lastUsedAt = Date.now();
    return {
      worker_session_id: session.id,
      url: page.url(),
      title: await page.title(),
      ...result,
    };
  } finally {
    session.busy = false;
  }
}

async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBodyBytes) throw new HttpError(413, "browser_request_too_large");
    chunks.push(chunk);
  }

  if (size === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch (_error) {
    throw new HttpError(400, "invalid_json");
  }
}

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "cache-control": "no-store",
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      const browser = await getBrowser();
      if (!browser.isConnected() || !pinnedProxyInstance?.listening) {
        throw new HttpError(503, "browser_unavailable");
      }
      send(res, 200, {
        status: "ok",
        egress_proxy: "dns_pinned",
        sessions: sessions.size,
        max_sessions: maxSessions,
        active_actions: activeActions,
      });
      return;
    }

    if (req.method === "POST" && req.url === "/actions") {
      if (activeActions >= maxConcurrentActions) {
        throw new HttpError(429, "browser_action_capacity_reached");
      }
      const payload = await readJson(req);
      activeActions += 1;
      try {
        send(res, 200, await execute(payload));
      } finally {
        activeActions -= 1;
      }
      return;
    }

    if (req.method === "DELETE" && req.url?.startsWith("/sessions/")) {
      const id = decodeURIComponent(req.url.slice("/sessions/".length));
      send(res, (await closeSession(id)) ? 200 : 404, { status: "closed" });
      return;
    }

    send(res, 404, { error: "not_found" });
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const code = error instanceof HttpError ? error.code : "browser_worker_error";
    if (status >= 500) console.error(error);
    if (!res.headersSent) send(res, status, { error: code });
  }
});

server.headersTimeout = 10_000;
server.requestTimeout = 35_000;
server.keepAliveTimeout = 5_000;
server.maxHeadersCount = 64;
server.maxRequestsPerSocket = 100;
server.maxConnections = Math.max(32, maxConcurrentActions * 4);

const cleanupTimer = setInterval(
  () => cleanupExpiredSessions().catch((error) => console.error("session cleanup failed", error)),
  Math.min(60_000, Math.max(5_000, Math.floor(sessionTtlMs / 2))),
);
cleanupTimer.unref();

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`Hydra browser worker received ${signal}; shutting down`);
  server.close();
  clearInterval(cleanupTimer);
  await Promise.all([...sessions.keys()].map(closeSession));
  if (browserInstance?.isConnected()) await browserInstance.close();
  if (pinnedProxyInstance?.listening) {
    pinnedProxyInstance.destroyTrackedSockets?.();
    await new Promise((resolve) => pinnedProxyInstance.close(resolve));
  }
  pinnedProxyInstance = null;
  pinnedProxyPromise = null;
}

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    shutdown(signal)
      .catch((error) => console.error("browser worker shutdown failed", error))
      .finally(() => process.exit(0));
  });
}

if (require.main === module) {
  server.listen(port, "0.0.0.0", () => {
    console.log(`Hydra browser worker listening on ${port}`);
  });
}

module.exports = {
  HttpError,
  assertPublicUrl,
  boundedTimeout,
  cleanupExpiredSessions,
  createPinnedProxy,
  hostMatchesAllowlist,
  isPrivateAddress,
  resolvePinnedAuthority,
  resolvePinnedHost,
  resolvePinnedUrl,
  throwIfProxyPolicyResponse,
};
