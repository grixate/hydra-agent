"use strict";

const assert = require("node:assert/strict");
const http = require("node:http");
const net = require("node:net");
const { Duplex, PassThrough, Readable } = require("node:stream");
const test = require("node:test");
const { chromium } = require("playwright");
const {
  boundedTimeout,
  createPinnedProxy,
  isPrivateAddress,
  resolvePinnedAuthority,
  resolvePinnedHost,
  resolvePinnedUrl,
  throwIfProxyPolicyResponse,
} = require("./server");

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server.address().port;
}

async function close(server) {
  server.destroyTrackedSockets?.();
  server.closeAllConnections?.();
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("proxy close timed out")), 1_000);
    server.close(() => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function requestProxy(port, target) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname: "127.0.0.1", port, method: "GET", path: target, agent: false },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () =>
          resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }),
        );
      },
    );
    req.on("error", reject);
    req.end();
  });
}

function connectProxy(port, authority) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    let response = "";
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("proxy CONNECT test timed out"));
    }, 2_000);
    socket.on("connect", () =>
      socket.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n\r\n`),
    );
    socket.on("data", (chunk) => {
      response += chunk.toString("utf8");
      if (response.includes("\r\n\r\n")) {
        clearTimeout(timeout);
        socket.destroy();
        resolve(response);
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

function upgradeProxy(port, target) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    let response = "";
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("proxy WebSocket test timed out"));
    }, 2_000);
    socket.on("connect", () =>
      socket.write(
        `GET ${target} HTTP/1.1\r\n` +
          "Host: rebind.test\r\n" +
          "Connection: Upgrade\r\n" +
          "Upgrade: websocket\r\n" +
          "Sec-WebSocket-Version: 13\r\n" +
          "Sec-WebSocket-Key: SG9zdC1waW5uaW5nLXRlc3Q=\r\n\r\n",
      ),
    );
    socket.on("data", (chunk) => {
      response += chunk.toString("utf8");
      if (response.includes("\r\n\r\n")) {
        clearTimeout(timeout);
        socket.destroy();
        resolve(response);
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

test("private and reserved IPv4 ranges fail closed", () => {
  for (const address of [
    "0.0.0.0",
    "10.0.0.1",
    "100.64.0.1",
    "127.0.0.1",
    "169.254.169.254",
    "172.16.0.1",
    "192.0.2.1",
    "192.168.1.1",
    "198.18.0.1",
    "198.51.100.1",
    "203.0.113.1",
    "224.0.0.1",
  ]) {
    assert.equal(isPrivateAddress(address), true, address);
  }
  assert.equal(isPrivateAddress("8.8.8.8"), false);
  assert.equal(isPrivateAddress("198.51.99.1"), false);
});

test("private, mapped, transition, and reserved IPv6 ranges fail closed", () => {
  for (const address of [
    "::",
    "::1",
    "::ffff:7f00:1",
    "::ffff:a00:1",
    "64:ff9b::7f00:1",
    "2002:7f00:1::",
    "fc00::1",
    "fd00::1",
    "fe80::1",
    "ff02::1",
    "2001:db8::1",
  ]) {
    assert.equal(isPrivateAddress(address), true, address);
  }
  assert.equal(isPrivateAddress("2606:4700:4700::1111"), false);
});

test("action timeouts are positive and bounded", () => {
  assert.equal(boundedTimeout(undefined, 1_000, 5_000), 1_000);
  assert.equal(boundedTimeout(-1, 1_000, 5_000), 1_000);
  assert.equal(boundedTimeout(20_000, 1_000, 5_000), 5_000);
});

test("DNS validation rejects a mixed public and private answer set", async () => {
  await assert.rejects(
    resolvePinnedHost("mixed.test", {
      allowPrivate: false,
      lookup: async () => [
        { address: "93.184.216.34", family: 4 },
        { address: "127.0.0.1", family: 4 },
      ],
    }),
    (error) => error.code === "private_network_blocked",
  );
});

test("CONNECT authority parsing preserves explicit ports for domains and IPv6", async () => {
  const domain = await resolvePinnedAuthority("example.test:80", {
    allowPrivate: false,
    lookup: async () => [{ address: "93.184.216.34", family: 4 }],
  });
  assert.equal(domain.port, 80);
  assert.equal(domain.address, "93.184.216.34");

  const ipv6 = await resolvePinnedAuthority("[2001:4860:4860::8888]:443", {
    allowPrivate: false,
  });
  assert.equal(ipv6.port, 443);
  assert.equal(ipv6.address, "2001:4860:4860::8888");

  await assert.rejects(
    resolvePinnedAuthority("example.test", {
      allowPrivate: false,
      lookup: async () => [{ address: "93.184.216.34", family: 4 }],
    }),
    (error) => error.code === "invalid_browser_url",
  );
});

test("disconnected clients never dial after a deferred DNS lookup", async () => {
  for (const kind of ["http", "connect"]) {
    const lookupStarted = deferred();
    const lookupResult = deferred();
    let httpRequestCount = 0;
    let connectCount = 0;
    const proxy = createPinnedProxy({
      lookup: async () => {
        lookupStarted.resolve();
        return lookupResult.promise;
      },
      httpRequest: () => {
        httpRequestCount += 1;
        throw new Error("HTTP dial should not occur after client disconnect");
      },
      connect: () => {
        connectCount += 1;
        throw new Error("CONNECT dial should not occur after client disconnect");
      },
    });
    const proxyPort = await listen(proxy);
    const client = net.connect({ host: "127.0.0.1", port: proxyPort });

    try {
      await new Promise((resolve, reject) => {
        client.once("connect", resolve);
        client.once("error", reject);
      });
      if (kind === "http") {
        client.write("GET http://deferred.test/ HTTP/1.1\r\nHost: deferred.test\r\n\r\n");
      } else {
        client.write("CONNECT deferred.test:443 HTTP/1.1\r\nHost: deferred.test:443\r\n\r\n");
      }
      await lookupStarted.promise;
      client.destroy();
      await new Promise((resolve) => client.once("close", resolve));
      await new Promise((resolve) => setTimeout(resolve, 20));
      lookupResult.resolve([{ address: "93.184.216.34", family: 4 }]);
      await new Promise((resolve) => setTimeout(resolve, 20));
      assert.equal(httpRequestCount, 0, kind);
      assert.equal(connectCount, 0, kind);
    } finally {
      client.destroy();
      lookupResult.resolve([{ address: "93.184.216.34", family: 4 }]);
      await close(proxy);
    }
  }
});

test("HTTP proxy pins the validated address and revalidates a rebound host", async () => {
  let lookupCount = 0;
  const upstreamRequests = [];
  const proxy = createPinnedProxy({
    lookup: async () => {
      lookupCount += 1;
      return lookupCount === 1
        ? [{ address: "93.184.216.34", family: 4 }]
        : [{ address: "127.0.0.1", family: 4 }];
    },
    httpRequest: (options, callback) => {
      upstreamRequests.push(options);
      const request = new PassThrough();
      request.setTimeout = () => request;
      queueMicrotask(() => {
        const response = Readable.from(["pinned"]);
        response.statusCode = 200;
        response.headers = { "content-type": "text/plain", connection: "close" };
        callback(response);
      });
      return request;
    },
  });
  const proxyPort = await listen(proxy);

  try {
    const first = await requestProxy(proxyPort, "http://rebind.test/resource?q=1");
    assert.equal(first.status, 200);
    assert.equal(first.body, "pinned");
    assert.equal(upstreamRequests.length, 1);
    assert.equal(upstreamRequests[0].hostname, "93.184.216.34");
    assert.equal(upstreamRequests[0].family, 4);
    assert.equal(upstreamRequests[0].headers.host, "rebind.test");
    assert.equal(upstreamRequests[0].path, "/resource?q=1");

    const rebound = await requestProxy(proxyPort, "http://rebind.test/redirect-hop");
    assert.equal(rebound.status, 403);
    assert.match(rebound.body, /private_network_blocked/);
    assert.equal(lookupCount, 2);
    assert.equal(upstreamRequests.length, 1);
  } finally {
    await close(proxy);
  }
});

test(
  "real Chromium revalidates a redirect hop and blocks DNS rebinding",
  { skip: process.env.HYDRA_BROWSER_INTEGRATION_TEST !== "1" },
  async () => {
    let lookupCount = 0;
    let upstreamCount = 0;
    const proxy = createPinnedProxy({
      lookup: async () => {
        lookupCount += 1;
        return lookupCount === 1
          ? [{ address: "93.184.216.34", family: 4 }]
          : [{ address: "169.254.169.254", family: 4 }];
      },
      httpRequest: (_options, callback) => {
        upstreamCount += 1;
        const request = new PassThrough();
        request.setTimeout = () => request;
        queueMicrotask(() => {
          const response = Readable.from([]);
          response.statusCode = 302;
          response.headers = {
            location: "http://rebind.test/private-target",
            "content-length": "0",
            connection: "close",
          };
          callback(response);
        });
        return request;
      },
    });
    const proxyPort = await listen(proxy);
    const browser = await chromium.launch({
      headless: true,
      chromiumSandbox: false,
      proxy: { server: `http://127.0.0.1:${proxyPort}` },
      args: ["--disable-quic", "--proxy-bypass-list=<-loopback>"],
    });

    try {
      const page = await browser.newPage();
      const response = await page.goto("http://rebind.test/first-hop", {
        waitUntil: "domcontentloaded",
      });
      assert.equal(response.status(), 403);
      assert.equal(page.url(), "http://rebind.test/private-target");
      await assert.rejects(
        throwIfProxyPolicyResponse(response),
        (error) => error.code === "private_network_blocked",
      );
      assert.equal(lookupCount, 2);
      assert.equal(upstreamCount, 1);
    } finally {
      await browser.close();
      await close(proxy);
    }
  },
);

test(
  "real Chromium cannot bypass the proxy for loopback or after proxy shutdown",
  { skip: process.env.HYDRA_BROWSER_INTEGRATION_TEST !== "1" },
  async () => {
    let originHits = 0;
    const origin = http.createServer((_req, res) => {
      originHits += 1;
      res.end("proxy bypassed");
    });
    await new Promise((resolve, reject) => {
      origin.once("error", reject);
      origin.listen(80, "127.0.0.1", resolve);
    });

    const proxy = createPinnedProxy();
    const proxyPort = await listen(proxy);
    const browser = await chromium.launch({
      headless: true,
      chromiumSandbox: false,
      proxy: { server: `http://127.0.0.1:${proxyPort}`, bypass: "<-loopback>" },
      args: ["--disable-quic"],
    });

    try {
      const page = await browser.newPage();
      const blocked = await page.goto("http://127.0.0.1/?through=proxy");
      assert.equal(blocked.status(), 403);
      await assert.rejects(
        throwIfProxyPolicyResponse(blocked),
        (error) => error.code === "private_network_blocked",
      );
      assert.equal(originHits, 0);

      await close(proxy);
      await assert.rejects(page.goto("http://127.0.0.1/?proxy=closed"));
      assert.equal(originHits, 0);
    } finally {
      await browser.close();
      if (proxy.listening) await close(proxy);
      origin.closeAllConnections?.();
      await new Promise((resolve) => origin.close(resolve));
    }
  },
);

test("HTTPS CONNECT dials the validated IP and blocks a rebound resolution", async () => {
  let lookupCount = 0;
  const connections = [];
  const proxy = createPinnedProxy({
    lookup: async () => {
      lookupCount += 1;
      return lookupCount === 1
        ? [{ address: "93.184.216.34", family: 4 }]
        : [{ address: "10.0.0.8", family: 4 }];
    },
    connect: (options) => {
      connections.push(options);
      const socket = new PassThrough();
      socket.setTimeout = () => socket;
      queueMicrotask(() => socket.emit("connect"));
      return socket;
    },
  });
  const proxyPort = await listen(proxy);

  try {
    const first = await connectProxy(proxyPort, "rebind.test:443");
    assert.match(first, /^HTTP\/1\.1 200 Connection Established/);
    assert.deepEqual(connections, [{ host: "93.184.216.34", port: 443, family: 4 }]);

    const rebound = await connectProxy(proxyPort, "rebind.test:443");
    assert.match(rebound, /^HTTP\/1\.1 403 Proxy Error/);
    assert.equal(lookupCount, 2);
    assert.equal(connections.length, 1);
  } finally {
    await close(proxy);
  }
});

test("WebSocket proxy pins the dial and rejects a rebound upgrade", async () => {
  const target = await resolvePinnedUrl("wss://socket.test/feed", ["ws:", "wss:"], {
    allowPrivate: false,
    lookup: async () => [{ address: "2606:4700:4700::1111", family: 6 }],
  });
  assert.equal(target.address, "2606:4700:4700::1111");
  assert.equal(target.family, 6);
  assert.equal(target.port, 443);

  let lookupCount = 0;
  const connections = [];
  let forwardedRequest = "";
  const proxy = createPinnedProxy({
    lookup: async () => {
      lookupCount += 1;
      return lookupCount === 1
        ? [{ address: "93.184.216.34", family: 4 }]
        : [{ address: "192.168.1.20", family: 4 }];
    },
    connect: (options) => {
      connections.push(options);
      let responded = false;
      const socket = new Duplex({
        read() {},
        write(chunk, _encoding, callback) {
          forwardedRequest += chunk.toString("utf8");
          if (!responded && forwardedRequest.includes("\r\n\r\n")) {
            responded = true;
            this.push(
              "HTTP/1.1 101 Switching Protocols\r\n" +
                "Connection: Upgrade\r\n" +
                "Upgrade: websocket\r\n\r\n",
            );
          }
          callback();
        },
      });
      socket.setTimeout = () => socket;
      queueMicrotask(() => socket.emit("connect"));
      return socket;
    },
  });
  const proxyPort = await listen(proxy);

  try {
    const first = await upgradeProxy(proxyPort, "ws://rebind.test/socket?stream=1");
    assert.match(first, /^HTTP\/1\.1 101 Switching Protocols/);
    assert.deepEqual(connections, [{ host: "93.184.216.34", port: 80, family: 4 }]);
    assert.match(forwardedRequest, /^GET \/socket\?stream=1 HTTP\/1\.1\r\n/m);
    assert.match(forwardedRequest, /\r\nHost: rebind\.test\r\n/i);

    const rebound = await upgradeProxy(proxyPort, "ws://rebind.test/next");
    assert.match(rebound, /^HTTP\/1\.1 403 Proxy Error/);
    assert.equal(lookupCount, 2);
    assert.equal(connections.length, 1);
  } finally {
    await close(proxy);
  }
});
