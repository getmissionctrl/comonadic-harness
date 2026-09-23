# AG-UI UI smoke test (assistant-ui)

A minimal [assistant-ui](https://www.assistant-ui.com) React frontend that drives
the comonadic harness over the **standard AG-UI transport**, to prove the
harness's AG-UI backend interoperates with a real, off-the-shelf AG-UI client —
not just our own hand-rolled JS.

It wires `@ag-ui/client`'s `HttpAgent` (the exact protocol client CopilotKit and
assistant-ui both build on) at the Haskell server's `POST /agent` endpoint via
`useAgUiRuntime`, and renders the streamed run with assistant-ui primitives.

## What it exercises

Browser → `POST /agent` (a standard `RunAgentInput`) → the server streams AG-UI
events back on that same response (`RUN_STARTED` → `TEXT_MESSAGE_*` →
`RUN_FINISHED`) → assistant-ui validates and renders them. The v1 server ships a
fake provider that answers `"hi"`, so a sent task comes back as an assistant
bubble saying `hi`.

## Run it by hand

```bash
# 1. the harness AG-UI server (defaults to :8080; use a free port if taken)
nix develop --command cabal run serve -- 8080

# 2. this app (from web/)
npm install
npm run dev              # http://localhost:5173
```

Open http://localhost:5173, type a task, press **Send** — the assistant reply
streams back. If your harness server is on a port other than 8080, point the app
at it: `VITE_AGENT_URL=http://localhost:PORT/agent npm run dev`.

## Automated headless check

`smoke.mjs` drives the built app in headless Chromium (Playwright), sends a task,
and asserts the assistant reply renders (writing `smoke.png`):

```bash
npm run build
VITE_AGENT_URL=http://localhost:8137/agent npm run build   # bake the server port in
# start `serve 8137` and `npx vite preview --port 5173`, then:
node smoke.mjs
```

The server's `POST /agent` sends permissive CORS, so the cross-origin browser
request (5173 → server port) is allowed.
