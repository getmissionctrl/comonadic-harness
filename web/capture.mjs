// Do two turns and print the exact RunAgentInput body of the SECOND request,
// so we can see how assistant-ui serialises message history (roles, content shape).
import { chromium } from "playwright";
const CHROME = "/nix/store/k6vmry8ij0ay963bxgfiazrcd6f112sc-playwright-chromium/chrome-linux/chrome";
const browser = await chromium.launch({ executablePath: CHROME, headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage();

let n = 0;
page.on("request", (req) => {
  if (req.method() === "POST" && req.url().endsWith("/agent")) {
    n++;
    console.log(`\n===== POST /agent #${n} body =====`);
    console.log(req.postData());
  }
});

await page.goto("http://localhost:5173", { waitUntil: "networkidle" });
const input = () => page.getByPlaceholder("Give the harness a task…");
const send = () => page.getByText("Send", { exact: true }).click();

// turn 1
await input().fill("My name is Ben and my favourite colour is teal.");
await send();
await page.waitForTimeout(6000); // let turn 1 finish

// turn 2 (depends on turn 1 context)
await input().fill("What is my name and favourite colour?");
await send();
await page.waitForTimeout(4000);

await browser.close();
