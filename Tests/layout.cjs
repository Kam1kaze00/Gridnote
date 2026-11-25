const engines = require("playwright");
const assert = require("node:assert/strict");

(async () => {
  const engine = process.env.ENGINE || "chromium";
  const browser = await engines[engine].launch(
    engine === "chromium" && process.env.BROWSER_BIN
      ? { executablePath: process.env.BROWSER_BIN }
      : {},
  );
  try {
    const page = await browser.newPage({
      viewport: { width: 1024, height: 768 },
      hasTouch: true,
    });
    await page.goto(process.env.GRIDNOTE_URL);
    await page.locator("#welcome-major").selectOption("Electrical Engineering");
    const names = await page.locator("#welcome-theme option").allTextContents();
    for (const name of names) {
      const picker = page.locator("#welcome-theme");
      await picker.selectOption(name);
      for (const [w, h] of [
        [320, 640],
        [390, 844],
        [768, 1024],
        [844, 390],
        [1024, 768],
        [1440, 900],
      ]) {
        await page.setViewportSize({ width: w, height: h });
        await page.evaluate(() => document.fonts.ready);
        const bounds = await picker.boundingBox();
        if (name === "Default") {
          const cover = await page.locator(".start-cover").boundingBox();
          assert(
            cover.x >= 0 && cover.x + cover.width <= w + 1 &&
              Math.abs(cover.width / cover.height - 4.2) < 0.01,
            "the whole Drafting Desk cover fits at " + w,
          );
        }
        assert(
          bounds.x >= 0 && bounds.x + bounds.width <= w + 1,
          name + " launcher field " + w,
        );
      }
      await page.click(name === "Default" ? "#new" : "#continue");
      await page.waitForSelector("#sheet");
      for (const [w, h] of [
        [320, 640],
        [390, 844],
        [768, 1024],
        [844, 390],
        [1024, 768],
        [1440, 900],
      ]) {
        await page.setViewportSize({ width: w, height: h });
        await page.evaluate(() => document.fonts.ready);
        const issues = await page.evaluate(() => {
          const errors = [];
          const rect = (e) => e.getBoundingClientRect();
          if (document.documentElement.scrollWidth > innerWidth + 1)
            errors.push("document overflow");
          for (const region of [
            "header",
            "#toolset",
            "#subject-strip",
            ".footer-pages",
            ".footer-zoom",
          ]) {
            const row = document.querySelector(region);
            const items = [...row.querySelectorAll("button")]
              .filter((b) => rect(b).width && rect(b).height)
              .map(rect);
            for (let i = 1; i < items.length; i++) {
              if (items[i].left < items[i - 1].right - 1)
                errors.push(region + " overlapping controls");
              if (
                Math.abs(
                  (items[i].top +
                    items[i].bottom -
                    items[i - 1].top -
                    items[i - 1].bottom) /
                    2,
                ) > 2
              )
                errors.push(region + " uneven centers");
            }
            if (region === "header" && items.at(-1)?.right > innerWidth + 1)
              errors.push("header actions clipped");
          }
          return errors;
        });
        assert.deepEqual(issues, [], name + " at " + w + "×" + h);
      }
      await page.setViewportSize({ width: 390, height: 844 });
      const buttons = page.locator("#subject-strip button");
      for (const b of [buttons.first(), buttons.last()]) {
        await b.click();
        await page
          .frameLocator(".subject-frame")
          .locator("#result")
          .waitFor({ state: "visible" });
        const box = await page.locator("#popover").boundingBox();
        assert(
          box.x >= -1 && box.x + box.width <= 391,
          name + " subject panel inside phone viewport",
        );
        await page.keyboard.press("Escape");
      }
      await page.click("#files");
      await page.getByRole("button", { name: "Notebook launcher…" }).click();
    }
    console.log(
      "PASS",
      engine,
      "five themes at six viewport sizes, aligned toolbar/major controls and reachable first/last subject tabs",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
