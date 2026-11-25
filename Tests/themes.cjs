const assert = require("node:assert/strict");
const engines = require("playwright");
async function main() {
  const engine = process.env.ENGINE || "chromium";
  const browser = await engines[engine].launch({
    ...(engine === "chromium" && process.env.BROWSER_BIN
      ? { executablePath: process.env.BROWSER_BIN }
      : {}),
  });
  try {
    const page = await browser.newPage({
      viewport: { width: 1024, height: 760 },
    });
    page.setDefaultTimeout(10000);
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(process.env.GRIDNOTE_URL);
    const launcherTheme = page.getByLabel("Theme", { exact: true });
    assert.equal(await launcherTheme.inputValue(), "Default");
    await launcherTheme.selectOption("70s Cartoon");
    assert(
      (
        await page
          .locator(".start-cover")
          .evaluate((el) => getComputedStyle(el).backgroundImage)
      ).includes("/launcher.jpg"),
    );
    await launcherTheme.selectOption("Default");
    assert(
      (
        await page
          .locator(".start-cover")
          .evaluate((el) => getComputedStyle(el).backgroundImage)
      ).includes("/default-cover.svg"),
    );
    const expected = [
      ["Tokyo Neon", "tokyo", "Transit"],
      ["Cyberpunk", "cyber", "Terminal"],
      ["Pixelated", "pixel", "Pixel"],
    ];
    for (const [name, id, font] of expected) {
      await launcherTheme.selectOption(name);
      await page.locator(".start-cover img").evaluate((img) => img.decode());
      assert.match(
        await page.locator(".start-cover img").getAttribute("src"),
        new RegExp(id + "-pencil"),
      );
      assert(
        await page.evaluate(async (font) => {
          await document.fonts.load("14px " + font);
          return (
            document.fonts.check("14px " + font) &&
            getComputedStyle(
              document.querySelector("#welcome-major"),
            ).fontFamily.includes(font)
          );
        }, font),
        name,
      );
    }
    await launcherTheme.selectOption("Default");
    await page.click("#new");
    await page.waitForSelector("#sheet");
    assert.match(
      await page.locator("#files img").getAttribute("src"),
      /pen-mark\.svg$/,
    );
    await page.click("#settings");
    const editorTheme = page.locator("#popover select[aria-label=Theme]");
    for (const [name, id] of expected) {
      await editorTheme.selectOption(name);
      await page.waitForFunction(
        (id) =>
          document
            .querySelector("#tool-brush use")
            .getAttribute("href")
            .includes(id + "-tools.svg"),
        id,
      );
      assert.match(
        await page.locator("#files img").getAttribute("src"),
        new RegExp(id + "-pencil"),
      );
    }
    await editorTheme.selectOption("70s Cartoon");
    assert.match(
      await page.locator("#files img").getAttribute("src"),
      /pencil\.png$/,
    );
    await page.keyboard.press("Escape");
    await page.click("#tool-brush");
    await page.getByRole("button", { name: "Pen", exact: true }).click();
    assert.equal(
      await page.locator("#tool-brush use").getAttribute("href"),
      "./assets/ink-tools.svg#pen",
    );
    await page.keyboard.press("Escape");
    await page.click("#paper");
    const stationery = page.getByLabel("Stationery");
    assert.equal(await stationery.inputValue(), "Default");
    await stationery.selectOption("70s Cartoon");
    await page
      .locator("#popover")
      .getByRole("button", { name: "Ivory", exact: true })
      .click();
    assert.equal(await stationery.inputValue(), "70s Cartoon");
    await page.keyboard.press("Escape");
    await page.waitForFunction(
      () => document.querySelector("#saved").textContent === "Saved",
    );
    await page.reload();
    await page.waitForSelector("#continue");
    assert.equal(await launcherTheme.inputValue(), "70s Cartoon");
    assert(
      await page
        .locator("body")
        .evaluate((el) => el.classList.contains("seventies")),
    );
    await page.click("#continue");
    await page.waitForSelector("#sheet");
    const result = await page.evaluate(async () => {
      const store = await import("./store.mjs"),
        render = await import("./render.mjs"),
        engine = await import("./engine.mjs");
      const record = await store.loadRecord(await store.loadState("last"));
      const edited = engine.paper(record.book, 0).cartoon;
      const pdf = await render.readPDF(await render.makePDF(record.book, null));
      const bitmap = await render.pdfBitmap(pdf, 0, 1000);
      const canvas = document.createElement("canvas");
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      const ctx = canvas.getContext("2d");
      ctx.drawImage(bitmap, 0, 0);
      const scale = bitmap.width / engine.W;
      const area = ctx.getImageData(
        Math.floor((engine.W - 43) * scale),
        Math.floor(4 * scale),
        Math.floor(34 * scale),
        Math.floor(32 * scale),
      ).data;
      let ink = 0;
      for (let i = 0; i < area.length; i += 4)
        if (area[i] < 165 && area[i + 3] > 180) ink++;
      await pdf.destroy();
      return { edited, ink };
    });
    assert.equal(result.edited, true);
    assert(result.ink > 70);
    await page.click("#files");
    await page
      .getByRole("button", { name: "New notebook", exact: true })
      .click();
    await page.waitForFunction(async () => {
      const s = await import("./store.mjs");
      const r = await s.loadRecord(await s.loadState("last"));
      return r?.book.defaultPaper?.cartoon === true;
    });
    await page.click("#settings");
    await page
      .getByRole("button", { name: "Restore all settings", exact: true })
      .click();
    assert.match(
      await page.locator("#files img").getAttribute("src"),
      /pen-mark\.svg$/,
    );
    assert.deepEqual(errors, []);
    console.log(
      "PASS",
      engine,
      "theme persistence, toolbar illustrations, opt-in paper, printed ornament and restored defaults",
    );
  } finally {
    await browser.close();
  }
}
main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
