import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createMcpBridge, MCP_PROTOCOL_VERSION } from "../lib/mcp-bridge.mjs";

// Two loopback ports are distinct origins. Only synthetic credentials reach them.
async function endpoint(t, handle = () => false) {
  const requests = [];
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString();
    const message = body ? JSON.parse(body) : null;
    const request = { method: req.method, path: req.url, headers: req.headers, body, message };
    requests.push(request);
    if (handle(request, res)) return;
    if (req.method !== "POST") { res.writeHead(405).end(); return; }
    if (message.id === undefined) { res.writeHead(202).end(); return; }
    const result = message.method === "initialize"
      ? { protocolVersion: MCP_PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: "redirect-fixture", version: "1" } }
      : message.method === "tools/list"
        ? { tools: [{ name: "echo", inputSchema: { type: "object" } }] }
        : { content: [{ type: "text", text: JSON.stringify(message.params.arguments) }] };
    res.writeHead(200, { "content-type": "application/json", "mcp-session-id": "test-session" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  return { url: `http://127.0.0.1:${server.address().port}/mcp`, requests };
}

function bridgeFor(t, url) {
  const bridge = createMcpBridge({ readConfig: () => ({
    mcpUrl: url,
    timeoutMs: 1000,
    apiKey: "fixture-key",
    sendIdentityHeaders: true,
    account: "fixture-account",
    user: "fixture-user",
    peerId: "fixture-peer",
    extraHeaders: { "X-API-Key": "fixture-extra-key" },
  }) });
  t.after(() => bridge.close());
  return bridge;
}

function assertIdentity(request, session = false) {
  assert.equal(request.headers.authorization, "Bearer fixture-key");
  assert.equal(request.headers["x-api-key"], "fixture-extra-key");
  assert.equal(request.headers["x-openviking-account"], "fixture-account");
  assert.equal(request.headers["x-openviking-user"], "fixture-user");
  assert.equal(request.headers["x-openviking-actor-peer"], "fixture-peer");
  if (session) assert.equal(request.headers["mcp-session-id"], "test-session");
}

for (const status of [301, 302, 303, 307, 308]) {
  for (const stage of ["initialize", "tools/call"]) {
    test(`HTTP ${status} blocks a cross-origin ${stage} redirect before sending data`, { timeout: 5000 }, async (t) => {
      const destination = await endpoint(t);
      const source = await endpoint(t, ({ message }, res) => {
        if (message?.method !== stage) return false;
        res.writeHead(status, { location: destination.url }).end();
        return true;
      });
      const bridge = bridgeFor(t, source.url);
      if (stage === "initialize") {
        await bridge.connect(1000);
      } else {
        assert.equal((await bridge.connect(1000)).connected, true);
        await assert.rejects(bridge.callTool("echo", { privateValue: "fixture-body" }), /redirect/i);
      }
      assert.equal(destination.requests.length, 0, "a foreign origin must receive no request");
      assert.equal(bridge.state.connected, false);
      assert.match(bridge.state.error, /redirect/i);
      const attempts = source.requests.filter((r) => r.message?.method === stage);
      assert.equal(attempts.length, 1, "the bridge must not replay the rejected request");
      assertIdentity(attempts[0], stage === "tools/call");
      if (stage === "tools/call") {
        assert.deepEqual(attempts[0].message.params.arguments, { privateValue: "fixture-body" });
      }
    });
  }
}

for (const status of [307, 308]) {
  test(`HTTP ${status} preserves same-origin initialization and tool calls`, { timeout: 5000 }, async (t) => {
    const source = await endpoint(t, ({ path, method }, res) => {
      if (path !== "/mcp" || method !== "POST") return false;
      res.writeHead(status, { location: "/mcp-final" }).end();
      return true;
    });
    const bridge = bridgeFor(t, source.url);
    assert.equal((await bridge.connect(1000)).connected, true);
    const result = await bridge.callTool("echo", { privateValue: "fixture-body" });
    assert.equal(result.content[0].text, '{"privateValue":"fixture-body"}');
    for (const stage of ["initialize", "notifications/initialized", "tools/list", "tools/call"]) {
      const original = source.requests.filter((r) => r.path === "/mcp" && r.message?.method === stage);
      const redirected = source.requests.filter((r) => r.path === "/mcp-final" && r.message?.method === stage);
      assert.equal(original.length, 1);
      assert.equal(redirected.length, 1);
      assert.equal(redirected[0].body, original[0].body);
      assertIdentity(redirected[0], stage !== "initialize");
    }
  });

  test(`HTTP ${status} rechecks the origin after a same-origin redirect`, { timeout: 5000 }, async (t) => {
    const destination = await endpoint(t);
    const source = await endpoint(t, ({ path }, res) => {
      res.writeHead(status, { location: path === "/mcp" ? "/next" : destination.url }).end();
      return true;
    });
    const bridge = bridgeFor(t, source.url);
    await bridge.connect(1000);
    assert.equal(destination.requests.length, 0, "a redirect chain must not escape the original origin");
    assert.equal(bridge.state.connected, false);
    assert.match(bridge.state.error, /redirect/i);
    assert.deepEqual(source.requests.map((r) => r.path), ["/mcp", "/next"]);
  });
}
