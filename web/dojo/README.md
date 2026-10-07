# Dojo renderers for the harness tool set

The [AG-UI **dojo**](https://github.com/ag-ui-protocol/ag-ui) (the
`demo-viewer` app in that monorepo) is an off-the-shelf AG-UI client. We use it
as a richer live viewer than `../` (our minimal assistant-ui smoke client):
it streams tool calls, chat messages, and reasoning (`THINKING_*`) and renders
each tool call with a custom card.

The dojo is **not vendored** here — it is a large third-party pnpm/nx monorepo.
What lives here is the small, at-risk piece of our work: the custom renderers
for *our* tool set, kept as a patch so they survive a reclone of the dojo.

## What the patch contains

`harness-renderers.patch` — a `git diff` against
`ag-ui-protocol/ag-ui` at commit **`e63fee1`**, touching two files:

- `apps/dojo/src/app/[integrationId]/feature/(v2)/backend_tool_rendering/page.tsx`
  — a `HarnessToolCard` plus a `useRenderTool` handler per harness tool
  (`read`, `write`, `commit`, `deref`, `jsonpath`, `scrape_url`), so each tool
  call renders as a labelled card instead of raw JSON.
- `apps/dojo/src/files.json` — registers the edited feature file so the dojo's
  source viewer lists it.

## Apply it

```bash
git clone https://github.com/ag-ui-protocol/ag-ui   # if you don't have it
cd ag-ui
git checkout e63fee1                                 # the base the patch was cut against
git apply /path/to/comonadic-harness/web/dojo/harness-renderers.patch
```

(The patch applies cleanly on `e63fee1`; on a newer dojo HEAD, apply with
`git apply --3way` and resolve.)

## Run it against `serve`

1. Start the harness AG-UI server (see the repo `README.md` for `.env`):

   ```bash
   nix develop --command cabal run serve -- 8088
   ```

2. Run the dojo per its own README (standard pnpm/nx Next.js monorepo; on a Nix
   box without corepack, `nix shell nixpkgs#pnpm nixpkgs#nodejs_22 nixpkgs#protobuf`
   and `pnpm config set manage-package-manager-versions false` first). Point its
   **server-starter-all-features** integration at `serve`:

   ```bash
   SERVER_STARTER_ALL_FEATURES_URL=http://<serve-host>:8088 pnpm --filter demo-viewer dev
   ```

   The dojo defaults this URL to `http://localhost:8000`; override it to reach
   `serve` (e.g. over Tailscale, `http://<host>:8088`).

3. Open the dojo, pick the **server-starter-all-features** integration and the
   **Backend Tool Rendering** feature, and drive a task.

## Why it works — the serve-side contract (already in this repo, on `main`)

- The dojo's all-features integration **POSTs to `/agent/<feature>`** (it appends
  the feature name to the base URL). `serve` routes any `POST /agent/...` to the
  one AG-UI handler — see `Harness.AgUi.Server` (`"agent":_` catch-all).
- `serve` streams the standard AG-UI event flow on that one response:
  `RUN_STARTED` → `TEXT_MESSAGE_*` / `TOOL_CALL_*` / `TOOL_CALL_RESULT` /
  `THINKING_*` → `RUN_FINISHED`. The renderers in the patch key off the
  `TOOL_CALL_*` events by tool name; reasoning shows via `THINKING_*`.
- Tools rendered match what `serve` affords: `read`, `write`, `commit`,
  `scrape_url`, plus the pass-by-reference selectors `deref` / `jsonpath`.

For a self-contained client that needs no external monorepo, use `../` (the
assistant-ui smoke app) instead — it drives the same `POST /agent` endpoint.
