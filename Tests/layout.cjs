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
      const bounds = await page.locator(".start-card").boundingBox();
      assert(bounds.x >= 0 && bounds.x + bounds.width <= w + 1 && bounds.width <= 429 &&
        Math.abs(bounds.x - (w - bounds.x - bounds.width)) <= 1,
        "launcher fits and is centered at " + w + ": " + JSON.stringify(bounds));
    }
    await page.click("#new");
    await page.waitForSelector("#sheet");
    await page.click("#page");
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
          if (region === "header") {
            if (items.at(-1)?.right > innerWidth + 1) errors.push("header actions clipped");
            if (matchMedia("(pointer: coarse)").matches && items.some(r => r.width < 44 || r.height < 44))
              errors.push("header actions are too small for touch");
          }
        }
        const sidebar = document.querySelector("#pages-panel");
        const heading = rect(sidebar.querySelector("strong"));
        const thumb = rect(sidebar.querySelector(".page-thumb"));
        const actions = [...sidebar.querySelectorAll("[data-action]")].map(rect);
        const touch = matchMedia("(pointer: coarse)").matches;
        const columns = touch ? 2 : 4;
        if (actions.length !== 4 || Math.abs(actions[0].left - heading.left) > 1 ||
            Math.abs(actions[0].left - thumb.left) > 1 ||
            Math.abs(actions[3].right - thumb.right) > 1 ||
            actions.some((r, i) => Math.abs(r.width - actions[0].width) > 1 ||
              Math.abs(r.top - actions[i - i % columns].top) > 1 ||
              (i >= columns && (r.top < actions[i-columns].bottom || Math.abs(r.left-actions[i-columns].left) > 1)) ||
              (touch && (r.width < 44 || r.height < 44))))
          errors.push("page actions and thumbnails do not share the same rail");
        for (const selected of [false, true]) {
          const selection = document.querySelector("#selection"), original = selection.hidden;
          selection.hidden = !selected;
          for (const button of document.querySelectorAll("footer button")) {
            const box = rect(button);
            if (box.width && (box.left < -1 || box.right > innerWidth + 1))
              errors.push("footer control outside viewport: " + button.id);
          }
          selection.hidden = original;
        }
        return errors;
      });
      assert.deepEqual(issues, [], "Layout at " + w + "×" + h);
    }
    await page.click("#page");
    await page.setViewportSize({ width: 390, height: 844 });
    async function fitsPanel(label) {
      const panel = page.locator("#popover");
      await panel.waitFor();
      const fits = () => page.evaluate(() => {
        const el = document.getElementById("popover"), b = el.getBoundingClientRect();
        return b.left >= 0 && b.top >= 0 && b.right <= innerWidth + 1 &&
          b.bottom <= innerHeight + 1 && el.scrollWidth <= el.clientWidth + 1;
      });
      assert(await fits(), label + " panel fits the viewport");
    }
    for (const control of await page.locator("#toolset button").all()) {
      await control.click();
      await fitsPanel(await control.getAttribute("id"));
      await page.keyboard.press("Escape");
    }
    await page.setViewportSize({width: 1024, height: 768});
    // Preview updates must preserve the focus and bitmap of unaffected pages.
    await page.click("#page");
    for (let i = 1; i < 6; i++) {
      await page.getByRole("button", {name:"Insert page after"}).click();
    }
    await page.getByRole("button", {name:"Go to page 1",exact:true}).click();
    await page.waitForFunction(() => document.querySelectorAll(".page-thumb canvas[width='150']").length === 6);
    await page.evaluate(() => { window.beforeThumbs = [...document.querySelectorAll(".page-thumb canvas")]; });
    await page.keyboard.press("q");
    const sheet = await page.locator("#sheet").boundingBox();
    await page.mouse.move(sheet.x + 80, sheet.y + 80);
    await page.mouse.down();
    await page.mouse.move(sheet.x + 130, sheet.y + 95, {steps: 6});
    await page.mouse.up();
    await page.waitForFunction(() => !window.beforeThumbs[0].isConnected);
    assert(await page.evaluate(() => window.beforeThumbs.slice(1).every(c => c.isConnected)), "other page previews stay in place");
    await page.click("#page");
    assert.equal(await page.locator(".page-thumb canvas").count(), 0, "a closed sidebar releases its preview canvases");

    await page.setViewportSize({width:844,height:390});
    const writer = page.getByRole("button", {name:"Writer",exact:true});
    await writer.focus();
    await page.keyboard.press("Enter");
    const panel = page.getByRole("dialog", {name:"Writer",exact:true});
    assert(await panel.evaluate(el => el.contains(document.activeElement)));
    const control = await writer.boundingBox(), popup = await panel.boundingBox();
    assert(popup.y >= control.y+control.height || popup.y+popup.height <= control.y, "landscape panel leaves its opener visible");
    await page.keyboard.press("Tab");
    assert(await panel.evaluate(el => document.activeElement !== el && el.contains(document.activeElement)));
    await page.keyboard.press("Shift+Tab");
    assert(await writer.evaluate(el => document.activeElement === el), "backward Tab can leave the panel");
    await page.keyboard.press("Enter");
    await page.keyboard.press("Escape");
    assert(await writer.evaluate(el => document.activeElement === el && el.getAttribute("aria-expanded") === "false"));
    await page.click("#preview");
    const preview = page.getByRole("dialog", {name:"PDF Preview"});
    await preview.waitFor();
    const next = await preview.getByRole("button", {name:"Next page"}).boundingBox();
    if (await page.evaluate(() => matchMedia("(pointer: coarse)").matches)) assert(next.width >= 44 && next.height >= 44);
    await page.click("#pdfclose");
    await page.click("#settings");
    await page.setViewportSize({width: 320, height: 640});
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    await fitsPanel("Options after rotation");
    await page.keyboard.press("Escape");
    await page.setViewportSize({width: 390, height: 844});
    await page.click("#files");
    await page.getByRole("button", { name: "Notebook launcher…" }).click();
    await page.locator("#continue").waitFor();
    console.log(
      "PASS",
      engine,
      "launcher, notebook, page and tool controls at six viewport sizes",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
