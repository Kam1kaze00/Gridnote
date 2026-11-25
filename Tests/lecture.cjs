const assert = require("node:assert/strict");
const { chromium, webkit, devices } = require("playwright");

(async () => {
  const ios = process.env.ENGINE === "webkit";
  const browser = await (ios ? webkit : chromium).launch(
    !ios && process.env.BROWSER_BIN ? { executablePath: process.env.BROWSER_BIN } : {},
  );
  try {
    const page = await browser.newPage({
      ...devices[ios ? "iPad (gen 7)" : "Pixel 7"],
      viewport: { width: ios ? 820 : 800, height: 1000 },
      deviceScaleFactor: 2,
    });
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.goto(process.env.GRIDNOTE_URL);
    await page.getByLabel("Major", { exact: true }).selectOption("Physics");
    await page.tap("#new");
    const sheet = page.locator("#sheet"), editor = page.locator("#editor");
    for (const id of ["tool-brush", "tool-eraser", "undo", "fit"]) {
      const b = await page.locator("#" + id).boundingBox();
      assert(b.width >= 44 && b.height >= 44, id + " has room for a fingertip");
    }
    async function tapPaper(x, y) {
      const box = await sheet.boundingBox();
      await page.touchscreen.tap(box.x + x, box.y + y);
    }
    await page.tap("#tool-text");
    await tapPaper(90, 280);
    await editor.fill("5x + 4 = 3");
    await page.tap("#edit-done");
    await editor.waitFor({ state: "hidden" });
    await page.tap("#solve");
    const answer = page.locator(".study-answer");
    assert.match(await answer.innerText(), /x = -0\.2/);
    await page.tap("#solve");
    await page.waitForFunction(() => document.getElementById("solve").getAttribute("aria-pressed") === "false");
    await tapPaper(90, 420);
    await editor.fill("3y = 12");
    await page.tap("#edit-done");
    await page.tap("#solve");
    await page.waitForFunction(() => document.getElementById("solve").getAttribute("aria-pressed") === "true");
    assert(await answer.isHidden());
    await tapPaper(102, 427);
    assert.match(await answer.innerText(), /y = 4/);

    await page.tap("#tool-table");
    await page.getByRole("button", { name: "Insert 2 columns by 1 row", exact: true }).tap();
    const table = await page.evaluate(async () => {
      const store = await import("./store.mjs");
      for (let attempt = 0; attempt < 40; attempt++) {
        const record = await store.loadRecord(await store.loadState("last"));
        const obj = record?.book.objects.find(o => o.table);
        if (obj) return obj;
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      throw Error("table did not autosave");
    });
    const scale = (await sheet.boundingBox()).width / (210 * 72 / 25.4);
    await tapPaper((table.frame[0][0] + 7) * scale, (table.frame[0][1] + 8) * scale);
    assert(await page.locator("#previous-cell").isDisabled());
    await editor.fill("Mass");
    await page.tap("#next-cell");
    await page.getByText("Row 1 · Column 2", { exact: true }).waitFor();
    assert(await page.locator("#next-cell").isDisabled());
    await editor.fill("2 kg");
    await page.tap("#previous-cell");
    await page.waitForFunction(() => document.getElementById("editor").value === "Mass");
    await page.tap("#edit-done");
    await page.tap("#page");
    await page.getByRole("button", { name: "Insert page after", exact: true }).tap();
    await page.tap("#page");
    await page.tap("#preview");
    await page.waitForFunction(() => document.getElementById("pdfcount").textContent === "2 / 2");
    await page.tap("#pdfprev");
    await page.waitForFunction(() => document.getElementById("pdfcount").textContent === "1 / 2");
    await page.tap("#pdfclose");

    await page.keyboard.press("q");
    const ink = await page.evaluate(async () => {
      const canvas = document.getElementById("sheet"), bounds = canvas.getBoundingClientRect();
      const frame = () => new Promise(requestAnimationFrame);
      const tick = async () => { await frame(); await frame(); };
      const pixelRatio = canvas.width / bounds.width;
      const capture = () => canvas.getContext("2d").getImageData(
        30 * pixelRatio, 90 * pixelRatio, 200 * pixelRatio, 90 * pixelRatio).data;
      await tick();
      const paper = capture();
      let allocated = 0;
      const create = Document.prototype.createElement;
      Document.prototype.createElement = function (tag, ...args) {
        if (tag === "canvas") allocated++;
        return create.call(this, tag, ...args);
      };
      function pen(type, x, y) {
        canvas.dispatchEvent(new PointerEvent(type, {
          bubbles: true, pointerId: 7, pointerType: "pen", button: 0,
          buttons: type === "pointerup" ? 0 : 1, pressure: 0.6,
          clientX: bounds.x + x, clientY: bounds.y + y,
        }));
      }
      try {
        for (let i = 0; i < 8; i++) {
          const x = 50 + 20 * i;
          pen("pointerdown", x, 115);
          await frame();
          pen("pointermove", x + 8, 150);
          pen("pointerup", x + 8, 150);
          await tick();
        }
      } finally { Document.prototype.createElement = create; }
      // Keep the tip cursor outside the sample and compare with a full repaint.
      pen("pointerleave", 300, 250);
      await tick();
      const warm = capture();
      document.getElementById("tool-selector").click();
      await tick();
      document.getElementById("tool-brush").click();
      await tick();
      const full = capture();
      return {
        allocated,
        ink: warm.reduce((n, v, i) => n + (Math.abs(v - paper[i]) > 24), 0),
        // WebKit and Chromium can choose different antialiasing for a read-back canvas.
        // A lost or displaced stroke produces high-contrast errors on the paper.
        differences: warm.reduce((n, v, i) => n + (Math.abs(v - full[i]) > 64), 0),
      };
    });
    assert(ink.allocated <= 2, "short strokes reuse the same page surface");
    assert(ink.ink > 500, "the measured area contains new ink");
    assert(ink.differences < ink.ink * 0.015, "cached ink matches a full page redraw");
    await page.tap("#undo");
    await page.waitForFunction(() => !document.getElementById("redo").disabled);
    await page.tap("#redo");
    await page.waitForFunction(() => document.getElementById("redo").disabled);
    await page.waitForFunction(() => document.getElementById("saved").textContent === "Saved");
    await page.reload();
    await page.tap("#continue");
    await page.waitForFunction(() => document.getElementById("page").textContent.trim() === "Page 2");
    const objects = await page.evaluate(async () => {
      const s = await import("./store.mjs");
      return (await s.loadRecord(await s.loadState("last"))).book.objects;
    });
    assert.deepEqual(objects.find(o => o.table).table.cells, ["Mass", "2 kg"]);
    assert.equal(objects.filter(o => o.content.ink).length, 8);
    assert.deepEqual(errors, []);
    console.log("PASS", ios ? "iPad WebKit" : "Android Chromium",
      "touch lecture, Solve, table entry, page preview, cached handwriting and resume");
  } finally { await browser.close(); }
})().catch(err => { console.error(err); process.exitCode = 1; });
