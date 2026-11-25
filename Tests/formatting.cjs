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
      viewport: { width: 970, height: 740 },
    });
    const errors = [];
    page.on("pageerror", (err) => errors.push(err.message));
    await page.goto(process.env.GRIDNOTE_URL);
    await page.click("#new");
    const pop = page.locator("#popover"),
      editor = page.locator("#editor");
    const tool = (id) => page.click("#tool-" + id);
    async function saved() {
      await page.waitForTimeout(400);
      return page.evaluate(async () => {
        const store = await import("./store.mjs");
        return (await store.loadRecord(await store.loadState("last"))).book
          .objects;
      });
    }
    const box = await page.locator("#sheet").boundingBox(),
      scale = box.width / ((210 * 72) / 25.4);
    const click = (x, y) =>
      page.mouse.click(box.x + x * scale, box.y + y * scale);
    await tool("table");
    const cell = pop.getByRole("button", {
      name: "Insert 3 columns by 2 rows",
      exact: true,
    });
    await cell.hover();
    assert.equal(await pop.locator(".insert-grid .lit").count(), 6);
    await cell.click();
    const [t] = await saved();
    assert.equal(t.table.rows, 2);
    assert.equal(t.table.columns, 3);
    const [x, y] = t.frame[0];
    await click(x + 8, y + 8);
    await editor.fill("Voltage");
    await editor.press("Tab");
    await editor.fill("Current");
    await editor.press("Shift+Tab");
    assert.equal(await editor.inputValue(), "Voltage");
    await tool("text");
    assert(await pop.getByText("Cell text", { exact: true }).isVisible());
    await pop.getByLabel("Text color").selectOption({ label: "Blue" });
    await pop.getByRole("button", { name: "Center", exact: true }).click();
    for (const name of ["Bold", "Italic", "Underline"])
      await pop.getByRole("button", { name, exact: true }).click();
    await page.keyboard.press("Escape");
    const styled = (await saved())[0];
    assert.equal(styled.table.formats["0:0"].traits, 7);
    assert.equal(styled.table.formats["0:0"].alignment, "Center");
    assert(!styled.table.formats["0:1"]);
    assert.deepEqual(styled.table.cells.slice(0, 2), ["Voltage", "Current"]);
    await tool("table");
    await pop.getByLabel("Table type size").selectOption("16");
    await page.keyboard.press("Escape");
    let [all] = await saved();
    assert.equal(all.content.text._2, 16);
    assert.equal(all.table.formats["0:0"].size, 16);
    assert.equal(all.table.formats["0:0"].traits, 7);
    await page.keyboard.press("Control+z");
    assert.equal((await saved())[0].content.text._2, 11);
    await page.keyboard.press("Control+Shift+z");
    assert.equal((await saved())[0].content.text._2, 16);
    await page.keyboard.press("r");
    await click(82, 225);
    await editor.fill("Energy balance");
    await editor.press("Control+Enter");
    await page.keyboard.press("w");
    await click(90, 230);
    await editor.fill("Energy and work");
    await tool("text");
    await pop.getByLabel("Text color").selectOption({ label: "Red" });
    await pop.getByRole("button", { name: "Bold", exact: true }).click();
    await pop.getByRole("button", { name: "Right", exact: true }).click();
    await pop
      .getByRole("slider", { name: "Type size", exact: true })
      .fill("21");
    await page.keyboard.press("Escape");
    const note = (await saved())[1];
    assert.equal(note.content.text._0, "Energy and work");
    assert.equal(note.content.text._2, 21);
    assert.equal(note.alignment, "Right");
    assert.equal(note.textTraits, 1);
    await page.keyboard.press("w");
    await page.mouse.move(box.x + 95 * scale, box.y + 231 * scale);
    await page.mouse.down();
    await page.mouse.move(box.x + 140 * scale, box.y + 255 * scale, {
      steps: 6,
    });
    await page.mouse.up();
    assert(await editor.isHidden());
    assert((await saved())[1].frame[0][0] > note.frame[0][0] + 20);
    await page.reload();
    await page.click("#continue");
    assert.deepEqual((await saved())[0].table, all.table);
    assert.deepEqual(errors, []);
    console.log(
      "PASS " +
        engine +
        " visual grid, Selector tap versus drag, cell navigation, whole-table and individual text styles, undo/redo and reopen.",
    );
  } finally {
    await browser.close();
  }
})().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
