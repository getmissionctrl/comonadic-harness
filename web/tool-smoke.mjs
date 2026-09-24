import { chromium } from "playwright";
const CHROME = "/nix/store/k6vmry8ij0ay963bxgfiazrcd6f112sc-playwright-chromium/chrome-linux/chrome";
const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage();
page.on("pageerror", (e) => console.log("PAGEERROR", String(e)));
await page.goto("http://localhost:5173", { waitUntil: "networkidle" });
await page.getByPlaceholder("Give the harness a task…").fill(
  "Use scrape_url to fetch https://example.com, then tell me in one sentence what the page is.",
);
await page.getByText("Send", { exact: true }).click();

// The tool-call card should appear BEFORE the final text answer.
await page.getByText(/🔧\s*scrape_url/i).waitFor({ timeout: 120000 });
console.log("TOOL CARD VISIBLE (before final answer)");
await page.screenshot({ path: "tool-smoke.png", fullPage: true });

// Then the model's summary lands.
await page.getByText(/domain/i).waitFor({ timeout: 120000 });
await page.waitForTimeout(1000);
await page.screenshot({ path: "tool-smoke-final.png", fullPage: true });
console.log("---- transcript ----");
console.log(await page.evaluate(() => document.body.innerText));
await browser.close();
