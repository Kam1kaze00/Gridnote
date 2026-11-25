const assert = require("node:assert/strict");
const engines = require("playwright");

(async () => {
  const engine = process.env.ENGINE || "chromium";
  const browser = await engines[engine].launch(
    engine === "chromium" && process.env.BROWSER_BIN
      ? { executablePath: process.env.BROWSER_BIN }
      : {},
  );
  try {
    const page = await browser.newPage({
      viewport: { width: 1024, height: 760 },
    });
    await page.addInitScript(() => {
      const original = CanvasRenderingContext2D.prototype.fillText;
      CanvasRenderingContext2D.prototype.fillText = function (value, ...args) {
        if (typeof value === "string" && / × .* mm/.test(value))
          window.lastSizeLabel = value;
        return original.call(this, value, ...args);
      };
    });
    await page.goto(process.env.GRIDNOTE_URL);
    await page.click("#new");
    const pixels = await page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 1200;
      canvas.height = 600;
      canvas.getContext("2d").fillRect(0, 0, 1200, 600);
      return canvas.toDataURL().split(",")[1];
    });
    await page.locator("#imagefile").setInputFiles({
      name: "exercise.png",
      mimeType: "image/png",
      buffer: Buffer.from(pixels, "base64"),
    });
    async function frame() {
      return await page.evaluate(async () => {
        const store = await import("./store.mjs");
        const rec = await store.loadRecord(await store.loadState("last"));
        return rec.book.objects.at(-1)?.frame;
      });
    }
    async function waitFrame(accept) {
      for (let tries = 0; tries < 120; tries++) {
        const value = await frame();
        if (value && accept(value)) return value;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      throw Error("Saved notebook did not reach the expected image dimensions");
    }
    const original = await waitFrame(() => true);
    assert(
      Math.abs(original[1][0] - 900) < 0.25 &&
        Math.abs(original[1][1] - 450) < 0.25,
      "oversized image inserted at original logical size",
    );
    assert.equal(original[0][0], 0);
    await page.click("#selection");
    await page.getByRole("button", { name: "Fit image to page" }).click();
    const fitted = await waitFrame((f) => f[1][0] < 595);
    assert(Math.abs(fitted[1][0] / fitted[1][1] - 2) < 0.001);
    const handle = await page.locator("#world").evaluate((world, f) => {
      const r = world.getBoundingClientRect(),
        scale = r.width / ((210 * 72) / 25.4);
      return [
        r.left + (f[0][0] + f[1][0]) * scale + 4,
        r.top + (f[0][1] + f[1][1]) * scale + 4,
      ];
    }, fitted);
    await page.mouse.move(...handle);
    await page.mouse.down();
    await page.mouse.move(handle[0] - 80, handle[1] - 40, { steps: 5 });
    await page.waitForFunction(
      () => window.lastSizeLabel?.includes("mm"),
      null,
      { timeout: 3000 },
    );
    await page.mouse.up();
    await waitFrame((f) => f[1][0] < fitted[1][0] - 10);
    await page.click("#undo");
    await waitFrame((f) => Math.abs(f[1][0] - fitted[1][0]) < 0.01);
    await page.click("#undo");
    await waitFrame((f) => f[1][0] === original[1][0]);
    const measured = await page.evaluate(async () => {
      const { imageSize } = await import("./image-size.mjs");
      const { resizeGuides } = await import("./blocks.mjs");
      const empty = imageSize(new Uint8Array(0), 400, 200);
      const png = new Uint8Array(29),
        v = new DataView(png.buffer);
      v.setUint32(0, 0x89504e47);
      v.setUint32(8, 9);
      v.setUint32(12, 0x70485973);
      v.setUint32(16, 5669);
      v.setUint32(20, 5669);
      png[24] = 1;
      const high = imageSize(png, 400, 200);
      const match = resizeGuides(
        [
          [0, 0],
          [105, 75],
        ],
        [
          [
            [125, 25],
            [104, 75],
          ],
        ],
        2,
        [0, 0],
      );
      return {
        empty,
        high,
        matches: match.matches,
        lines: match.guides.length,
      };
    });
    assert.deepEqual(measured.empty, [300, 150]);
    assert(Math.abs(measured.high[0] - 200) < 0.1);
    assert.deepEqual(measured.matches, ["W", "H"]);
    assert(measured.lines >= 12);
    console.log(
      "PASS",
      engine,
      "original-size image insertion, explicit fit and undo, Retina density and resize alignment guides",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
