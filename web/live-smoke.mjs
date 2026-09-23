// Headless browser test of the LIVE agent: type a scrape task, wait for the
// model's streamed reply (which requires a real scrape_url tool call), screenshot.
import { chromium } from "playwright";
const CHROME = "/nix/store/k6vmry8ij0ay963bxgfiazrcd6f112sc-playwright-chromium/chrome-linux/chrome";
const URL = process.env.APP_URL || "http://localhost:5173";

const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage();
page.on("pageerror", (e) => console.log("PAGEERROR", String(e)));
page.on("console", (m) => m.type() === "error" && !m.text().includes("Failed to load resource") && console.log("CONSOLE", m.text()));

await page.goto(URL, { waitUntil: "networkidle" });
await page.getByPlaceholder("Give the harness a task…").fill(
  "Use scrape_url to fetch https://example.com, then tell me in one sentence what the page is.",
);
await page.getByText("Send", { exact: true }).click();

// Live model + Firecrawl: wait for content only the assistant/tool produces.
// "domain" appears in example.com's scraped text + the reply, never in the prompt.
await page.getByText(/domain/i).waitFor({ timeout: 170000 });
await page.waitForTimeout(1500);
await page.screenshot({ path: "live-smoke.png", fullPage: true });
console.log("LIVE SMOKE OK — assistant reply rendered; screenshot -> web/live-smoke.png");
console.log("---- transcript ----");
console.log(await page.evaluate(() => document.body.innerText));
await browser.close();
