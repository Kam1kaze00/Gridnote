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
    const pageWidth = (210 * 72) / 25.4;
    async function expectedSize(w, h) {
      const visible = await page.locator("#view").evaluate(el => {
        const zoomedWidth = document.getElementById("world").getBoundingClientRect().width;
        return [el.clientWidth / zoomedWidth, el.clientHeight / zoomedWidth];
      });
      const factor = Math.min(1, (150 * 72 / 25.4) / w, (100 * 72 / 25.4) / h,
        visible[0] * pageWidth * 0.85 / w, visible[1] * pageWidth * 0.6 / h);
      return [w * factor, h * factor];
    }
    const expected = await expectedSize(900, 450);
    assert(original[1].every((v, i) => Math.abs(v - expected[i]) < 0.25));
    assert(original[0][0] > 0 && original[0][0] + original[1][0] < pageWidth);
    const stored = await page.evaluate(async () => {
      const s = await import("./store.mjs");
      return (await s.loadRecord(await s.loadState("last"))).book.objects[0].content.image._0;
    });
    assert.equal(stored, pixels, "placing a smaller photo preserves the PNG pixels");
    await page.click("#selection");
    await page.getByRole("button", { name: "Fit image to page" }).click();
    const fitted = await waitFrame((f) => f[1][0] > original[1][0] + 1);
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
    // Exercise an external clipboard paste, including placement on the second page at higher zoom.
    await page.click("#page");
    await page.getByRole("button", {name: "Insert page after", exact: true}).click();
    await page.click("#page");
    await page.click("#zoomin");
    async function pasteBitmap(width, height) {
      await page.evaluate(async ([w, h]) => {
        const c = document.createElement("canvas");
        c.width = w; c.height = h;
        const blob = await new Promise(resolve => c.toBlob(resolve));
        const clipboard = new DataTransfer();
        clipboard.items.add(new File([blob], "portrait.png", { type: "image/png" }));
        const event = new Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(event, "clipboardData", { value: clipboard });
        document.querySelector("#sheet").dispatchEvent(event);
      }, [width, height]);
    }
    await pasteBitmap(800, 2400);
    const portrait = await waitFrame(f => f[1][1] > f[1][0]);
    const target = await expectedSize(600, 1800);
    assert(portrait[1].every((v, i) => Math.abs(v - target[i]) < 0.25));
    const H = 297 * 72 / 25.4;
    assert(portrait[0][1] >= H && portrait[0][1] + portrait[1][1] < 2 * H);
    // Paste just above the next page break and verify the complete image is visible on this page.
    await page.locator("#view").evaluate((view, h) => {
      const scale = document.getElementById("world").getBoundingClientRect().width / (210 * 72 / 25.4);
      view.scrollTop = (2 * h - 105) * scale;
    }, H);
    await pasteBitmap(1600, 1200);
    const nearBreak = await waitFrame(f => f[1][0] > f[1][1] && f[0][1] > H);
    assert(nearBreak[0][1] + nearBreak[1][1] <= 2 * H - 5 * 72 / 25.4 + 0.1);
    await pasteBitmap(80, 40);
    await waitFrame(f => Math.abs(f[1][0] - 60) < 0.1 && Math.abs(f[1][1] - 30) < 0.1);
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
      "bounded import and portrait paste, native-size small crops, original PNG pixels, fit/undo, Retina density and resize guides",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
