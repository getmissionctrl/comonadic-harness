// Headless browser smoke test: load the built assistant-ui app, send a task,
// and assert the harness's streamed assistant reply renders. Proves the full
// round-trip browser -> POST /agent (SSE) -> assistant-ui.
import { chromium } from "playwright";

const CHROME =
  process.env.CHROME_PATH ||
  "/nix/store/k6vmry8ij0ay963bxgfiazrcd6f112sc-playwright-chromium/chrome-linux/chrome";
const URL = process.env.APP_URL || "http://localhost:5173";

const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage();
const errors = [];
// Ignore benign resource 404s (e.g. /favicon.ico from the preview server); keep
// real application errors such as the AG-UI event-validation failures.
page.on("console", (m) => {
  if (m.type() === "error" && !m.text().includes("Failed to load resource")) errors.push(m.text());
});
page.on("pageerror", (e) => errors.push(String(e)));

await page.goto(URL, { waitUntil: "networkidle" });
await page.locator("h1").waitFor();

// Type a task and send it.
const input = page.getByPlaceholder("Give the harness a task…");
await input.waitFor();
await input.fill("hello from playwright");
await page.getByText("Send", { exact: true }).click();

// The fake provider answers "hi"; assert it renders as an assistant bubble.
await page.getByText("hi", { exact: true }).waitFor({ timeout: 10000 });

// Also confirm our typed message rendered (round-trip echo).
await page.getByText("hello from playwright").waitFor({ timeout: 5000 });

await page.screenshot({ path: "smoke.png", fullPage: true });
await browser.close();

if (errors.length) {
  console.error("PAGE ERRORS:\n" + errors.join("\n"));
  process.exit(1);
}
console.log("SMOKE OK: assistant reply 'hi' rendered; screenshot -> web/smoke.png");
