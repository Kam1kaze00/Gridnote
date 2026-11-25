const assert = require("node:assert/strict");
const engines = require("playwright");

async function main() {
  const engine = process.env.ENGINE || "chromium";
  const browser = await engines[engine].launch({
    headless: true,
    ...(engine === "chromium" && process.env.BROWSER_BIN
      ? { executablePath: process.env.BROWSER_BIN }
      : {}),
  });
  try {
    const page = await browser.newPage({
      viewport: { width: 768, height: 900 },
    });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.setDefaultTimeout(10000);
    await page.goto(process.env.GRIDNOTE_URL);
    const major = page.getByLabel("Major", { exact: true });
    await major.locator("option").first().waitFor({ state: "attached" });
    const names = await major.locator("option").allTextContents();
    assert.equal(names.length, 8);
    for (const name of names) {
      await major.selectOption(name);
      const preview = await page
        .locator(".start-preview span")
        .allTextContents();
      await page.click(name === "None" ? "#new" : "#continue");
      await page.waitForSelector("#sheet");
      assert(await page.locator("#tool-brush").isVisible());
      const shortcuts = page.locator("#subject-strip button");
      assert.deepEqual(await shortcuts.allTextContents(), preview);
      assert.equal(preview.length, name === "None" ? 0 : 6);
      for (const label of preview) {
        await page
          .locator("#subject-strip")
          .getByRole("button", { name: label, exact: true })
          .click();
        const panel = page.frameLocator("iframe.subject-frame");
        await panel.locator("#insert:enabled").waitFor();
        assert.equal(await panel.locator("#tool").inputValue(), label);
        assert((await panel.locator("#result").textContent()).trim());
        await page.waitForFunction(() => {
          const frame = document.querySelector(".subject-frame");
          const body = frame?.contentDocument?.body;
          return body && Math.abs(frame.clientHeight - body.getBoundingClientRect().height) < 2;
        });
        await page.locator("#subject-strip strong").click();
      }
      await page.click("#files");
      await page
        .getByRole("button", { name: "Notebook launcher…", exact: true })
        .click();
      await major.waitFor();
      assert(!(await page.locator("#sheet").isVisible()));
    }
    assert.deepEqual(errors, []);
    console.log(
      "PASS",
      engine,
      "startup, all 42 major shortcuts, live results, regular tools and return to the launcher",
    );
  } finally {
    await browser.close();
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
