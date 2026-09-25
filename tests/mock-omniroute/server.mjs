// Mock OmniRoute HTTP server for sandbox testing.
// Implements the exact endpoint contract of OmniRoute v3.8.51 that
// OmniRoute (root script) relies on:
//   GET  /healthz                -> 200 {"status":"ok"} (lightweight liveness)
//   POST /api/auth/login         -> {"password": admin} -> Set-Cookie auth_token
//   POST /api/providers/bulk     -> auth_token cookie; {"provider","entries":[...]}
//                                   -> {"created":[...],"errors":[]}
//   GET  /v1/models              -> Bearer master key -> {"object":"list","data":[...]}
//   POST /v1/chat/completions    -> Bearer master key; model must exist in catalog
//                                   (models with "mockFail":true return 502)
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const STATE = process.env.MOCK_STATE || "/tmp/omniroute-mock-state";
const ADMIN_PASSWORD = process.env.MOCK_ADMIN_PASSWORD || "adminpw";
const MASTER_KEY = process.env.MOCK_MASTER_KEY || "sk-omni-mock";
const CATALOG_FILE = process.env.MOCK_CATALOG;
const BOOT_DELAY_MS = Number(process.env.MOCK_BOOT_DELAY ?? 3000);
const PORT = Number(process.env.MOCK_PORT || 20128);

fs.writeFileSync(path.join(STATE, `server-pid-${process.pid}`), String(process.pid));
// Conventional pid file the mock `docker stop` kills.
const nameFile = path.join(STATE, "container-name");
const name = fs.existsSync(nameFile) ? fs.readFileSync(nameFile, "utf8").trim() : "omniroute-app";
fs.writeFileSync(path.join(STATE, `server-${name}.pid`), String(process.pid));

function log(...a) {
  const line = `[mock-omniroute ${new Date().toISOString()}] ${a.join(" ")}`;
  fs.appendFileSync(path.join(STATE, `server-${name}.log`), line + "\n");
  console.log(line);
}

log(`booting (simulating first-boot delay ${BOOT_DELAY_MS}ms) admin=${ADMIN_PASSWORD ? "set" : "MISSING"} master=${MASTER_KEY === "sk-omni-mock" ? "<default>" : "set"}`);

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const send = (code, obj, headers = {}) => {
    const body = typeof obj === "string" ? obj : JSON.stringify(obj);
    res.writeHead(code, { "Content-Type": "application/json", ...headers });
    res.end(body);
  };
  const readBody = () =>
    new Promise((resolve) => {
      let data = "";
      req.on("data", (c) => (data += c));
      req.on("end", () => resolve(data));
    });

  log(`${req.method} ${req.url}`);

  if (req.method === "GET" && url.pathname === "/healthz") {
    return send(200, { status: "ok" });
  }

  if (req.method === "POST" && url.pathname === "/api/auth/login") {
    readBody().then((raw) => {
      let pw;
      try {
        pw = JSON.parse(raw).password;
      } catch {
        return send(400, { error: "Invalid JSON body" });
      }
      if (pw === ADMIN_PASSWORD) {
        return send(200, { success: true }, {
          "Set-Cookie": "auth_token=mock-jwt-token; HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000",
        });
      }
      return send(401, { error: "Invalid password" });
    });
    return;
  }

  const isAuthed = (req) => {
    const c = req.headers.cookie || "";
    return c.includes("auth_token=mock-jwt-token");
  };
  const bearer = (req) => {
    const h = req.headers.authorization || "";
    return h.startsWith("Bearer ") ? h.slice(7) : null;
  };

  if (req.method === "POST" && url.pathname === "/api/providers/bulk") {
    if (!isAuthed(req)) return send(403, { error: "Invalid management token" });
    readBody().then((raw) => {
      let body;
      try {
        body = JSON.parse(raw);
      } catch {
        return send(400, { error: "Invalid JSON body" });
      }
      const provider = body.provider;
      const entries = Array.isArray(body.entries) ? body.entries : [];
      const known = ["groq", "openrouter", "gemini", "cerebras", "mistral"];
      if (!known.includes(provider)) return send(400, { error: "Invalid provider" });
      const file = path.join(STATE, "connections.json");
      let conns = [];
      try {
        conns = JSON.parse(fs.readFileSync(file, "utf8"));
      } catch {}
      const created = [];
      const errors = [];
      for (const e of entries) {
        // upsert by name (mirrors OmniRoute #2587 behaviour)
        const idx = conns.findIndex((c) => c.provider === provider && c.name === e.name);
        const rec = { id: `conn-${Math.random().toString(16).slice(2, 10)}`, provider, name: e.name, apiKey: e.apiKey, authType: "apikey", testStatus: "unknown" };
        if (idx >= 0) conns[idx] = rec;
        else conns.push(rec);
        created.push(rec);
      }
      fs.writeFileSync(file, JSON.stringify(conns, null, 2));
      return send(200, { created, errors });
    });
    return;
  }

  let catalog = [];
  try {
    catalog = JSON.parse(fs.readFileSync(CATALOG_FILE, "utf8"));
  } catch (e) {
    log("catalog load failed:", e.message);
  }

  if (req.method === "GET" && url.pathname === "/v1/models") {
    if (bearer(req) !== MASTER_KEY) return send(401, { error: "Invalid API key" });
    return send(200, { object: "list", data: catalog.map((m) => ({ id: m.id, object: "model", owned_by: m.owned_by || "omniroute", ...m, mockFail: undefined })) });
  }

  if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
    if (bearer(req) !== MASTER_KEY) return send(401, { error: "Invalid API key" });
    readBody().then((raw) => {
      let body;
      try {
        body = JSON.parse(raw);
      } catch {
        return send(400, { error: "Invalid JSON body" });
      }
      const m = catalog.find((c) => c.id === body.model);
      if (!m) return send(404, { error: { message: `Model '${body.model}' not found`, type: "invalid_request_error" } });
      if (m.mockFail) return send(502, { error: { message: `Upstream provider error (mock) for ${body.model}`, type: "upstream_error" } });
      return send(200, {
        id: `chatcmpl-mock-${Date.now()}`,
        object: "chat.completion",
        model: body.model,
        choices: [
          {
            index: 0,
            message: { role: "assistant", content: `Hello from mock OmniRoute via ${body.model}!` },
            finish_reason: "stop",
          },
        ],
        usage: { prompt_tokens: 9, completion_tokens: 12, total_tokens: 21 },
      });
    });
    return;
  }

  return send(404, { error: `mock: no route for ${req.method} ${url.pathname}` });
});

setTimeout(() => {
  server.listen(PORT, "127.0.0.1", () => log(`listening on 127.0.0.1:${PORT}`));
}, BOOT_DELAY_MS);

process.on("SIGTERM", () => {
  log("SIGTERM - shutting down");
  server.close();
  process.exit(0);
});
process.on("SIGINT", () => process.exit(0));
