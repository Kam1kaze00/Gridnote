const { webkit, devices } = require("playwright");
const assert = require("node:assert/strict");
(async () => {
  const browser = await webkit.launch();
  try {
    const ctx = await browser.newContext({
      ...devices["iPad (gen 7)"],
      viewport: { width: 820, height: 1050 },
      isMobile: true,
      hasTouch: true,
    });
    const page = await ctx.newPage(),
      errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(process.env.GRIDNOTE_URL || "http://127.0.0.1:8793/");
    assert(!(await page.locator("#detected-device").isVisible()));
    await page.tap("#new");
    const sheet = page.locator("#sheet");
    async function ptr(type, id, pointerType, x, y, pressure = 0.55) {
      const box = await sheet.boundingBox();
      await sheet.dispatchEvent(type, {
        pointerId: id,
        pointerType,
        clientX: box.x + x,
        clientY: box.y + y,
        button: 0,
        buttons: type === "pointerup" ? 0 : 1,
        pressure,
        bubbles: true,
      });
    }
    async function saved() {
      await page.waitForTimeout(400);
      return page.evaluate(async () => {
        const s = await import("./store.mjs");
        return (await s.loadRecord(await s.loadState("last"))).book;
      });
    }
    await ptr("pointerdown", 1, "pen", 80, 180, 0.2);
    await ptr("pointerdown", 2, "touch", 100, 230);
    await ptr("pointermove", 1, "pen", 180, 180, 0.6);
    await ptr("pointermove", 1, "pen", 290, 180, 0.95);
    await ptr("pointercancel", 2, "touch", 100, 230);
    await ptr("pointerup", 1, "pen", 290, 180);
    const original = await saved();
    assert.equal(original.objects.length, 1);
    assert(
      new Set(original.objects[0].content.ink._0.map((p) => p.radius)).size > 1,
    );
    await page.tap("#tool-eraser");
    await page.getByRole("button", { name: "Regular", exact: true }).tap();
    await ptr("pointerdown", 3, "pen", 180, 140);
    await ptr("pointermove", 3, "pen", 180, 215);
    await ptr("pointerup", 3, "pen", 180, 215);
    assert.equal((await saved()).objects.length, 2);
    await page.keyboard.press("Meta+z");
    assert.deepEqual((await saved()).objects, original.objects);
    await page.tap("#tool-brush");
    await page.getByRole("button", { name: "Pen", exact: true }).tap();
    await page.getByLabel("Use pen pressure").uncheck();
    await ptr("pointerdown", 4, "pen", 80, 240, 0.1);
    await ptr("pointermove", 4, "pen", 180, 250, 0.95);
    await ptr("pointerup", 4, "pen", 180, 250);
    assert.equal(
      new Set(
        (await saved()).objects.at(-1).content.ink._0.map((p) => p.radius),
      ).size,
      1,
    );
    await page.tap("#tool-brush");
    await page.getByRole("button", { name: "Restore tool defaults" }).tap();
    assert(await page.getByLabel("Use pen pressure").isChecked());
    await page.keyboard.press("Escape");
    await page.tap("#tool-selector");
    await page.keyboard.press("Escape");
    await ptr("pointerdown", 7, "touch", 110, 180);
    await ptr("pointerup", 7, "touch", 110, 180);
    assert(
      await page.locator("#selection").isVisible(),
      "finger tap selects handwriting",
    );
    await page.tap("#tool-brush");
    await page.keyboard.press("Escape");
    await ptr("pointerdown", 21, "touch", 190, 300);
    await ptr("pointerdown", 22, "touch", 360, 300);
    await ptr("pointermove", 22, "touch", 470, 320);
    await ptr("pointerup", 22, "touch", 470, 320);
    await ptr("pointerup", 21, "touch", 190, 300);
    assert.equal((await saved()).objects.length, 2);
    assert(await page.locator("#fit").isEnabled());
    await page.tap("#fit");
    await page.locator("#view").evaluate((el) => el.scrollTo(0, 350));
    await saved();
    await page.tap("#settings");
    await page.getByRole("button", { name: "Restore all settings" }).tap();
    const before = await page.locator("#view").evaluate((el) => el.scrollTop);
    assert(before > 100);
    await page.reload();
    await page.tap("#continue");
    await page.waitForSelector("#sheet");
    assert.equal((await saved()).objects.length, 2);
    assert(
      Math.abs(
        before - (await page.locator("#view").evaluate((el) => el.scrollTop)),
      ) < 4,
    );
    for (const size of [
      { width: 1024, height: 768 },
      { width: 390, height: 800 },
    ]) {
      await page.setViewportSize(size);
      await page.tap("#tool-brush");
      const tips = page.locator("#popover .writing-tips button");
      const boxes = await tips.evaluateAll(buttons => buttons.map(button => {
        const {x, y, width, height} = button.getBoundingClientRect();
        return {x, y, width, height};
      }));
      assert.equal(boxes.length, 6);
      for (const [i, box] of boxes.entries()) {
        assert(box.width >= 44 && box.height >= 44, "each tip has a full touch target");
        assert.equal(box.x, boxes[i % 3].x);
        assert.equal(box.y, boxes[i < 3 ? 0 : 3].y);
      }
      assert(boxes[3].y >= boxes[0].y + boxes[0].height);
      const p = await page.locator("#popover").boundingBox();
      assert(
        p.x >= 0 &&
          p.y >= 0 &&
          p.x + p.width <= size.width + 1 &&
          p.y + p.height <= size.height + 1,
      );
      assert(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
      );
      await page.keyboard.press("Escape");
    }
    assert.deepEqual(errors, []);
    console.log(
      "PASS iPad WebKit portrait, landscape and split-width layout; pencil pressure, palm rejection, regular erase/undo, finger selection, pinch zoom, tool and global resets, autosave and resume.",
    );
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
