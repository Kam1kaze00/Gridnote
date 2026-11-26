const waitForStoredValue = require("./wait-for-storage.cjs");
const assert = require("node:assert/strict");
const path = require("node:path");
const { chromium, firefox, webkit } = require("playwright");

async function editHistory(page) {
  await page.click("#new");
  await page.keyboard.press("r");
  const sheet = await page.locator("#sheet").boundingBox();
  await page.mouse.click(sheet.x + 100, sheet.y + 100);
  await page.fill("#editor", "First observation");
  await page.keyboard.press("Control+Enter");
  await page.mouse.click(sheet.x + 100, sheet.y + 170);
  await page.fill("#editor", "Second observation");
  await page.click("#files");
  await page.locator("#popover").getByRole("button", { name: "Undo", exact: true }).click();
  assert(await page.locator("#redo").isEnabled(), "Undoing the open text edit must leave it available for Redo");
  await page.click("#redo");
  await waitForStoredValue(page, async () => {
    const s = await import("./store.mjs");
    const record = await s.loadRecord(await s.loadState("last"));
    return record?.book.objects.some(o => o.content.text?._0 === "Second observation");
  });
}

async function lastPage(page) {
  await page.click("#new");
  await page.click("#page");
  await page.getByRole("button", { name: "Insert page after" }).click();
  await page.waitForFunction(() => document.querySelector("#page").textContent === "Page 2");
  await page.click("#files");
  await page.locator("#popover").getByRole("button", { name: "Delete this page" }).click();
  assert.equal(await page.locator("#page").textContent(), "Page 1", "the menu should land on the remaining page");
  await page.click("#undo");
  await page.getByRole("button", { name: "Go to page 2", exact: true }).waitFor();
}

async function inheritedPaper(page) {
  await page.click("#new");
  await page.click("#paper");
  const options = page.locator("#popover");
  const choose = (name) => options.getByRole("button", { name, exact: true }).click();
  await choose("Grid");
  assert(await page.locator("#undo").isDisabled(), "Choosing the current paper must leave Undo alone");
  await choose("Dotted");
  await choose("Grid");
  await choose("Notebook default");
  await choose("Ruled");
  await page.keyboard.press("Escape");
  assert.match(await page.locator("#paper").textContent(), /Ruled/, "a reset page follows later notebook defaults");
}

async function editDuringPDFOpen(page) {
  const pick = async name => {
    await page.click("#files");
    await page.locator("#popover").getByRole("button", { name, exact: true }).click();
  };
  await page.setInputFiles("#file", path.join(__dirname, "fixtures/exercise.pdf"));
  await waitForStoredValue(page, async () => (await (await import("./store.mjs")).lastNotebookInfo())?.title === "exercise");
  await pick("New notebook");
  await waitForStoredValue(page, async () => (await (await import("./store.mjs")).lastNotebookInfo())?.title === "Untitled Notebook");
  const outgoing = await page.evaluate(async () => {
    // Hold one PDF-worker reply long enough to type in the notebook still on screen.
    const send = Worker.prototype.postMessage;
    Worker.prototype.postMessage = function(message, ...args) {
      if (message?.action === "GetDocRequest" && !window.finishPDFOpen) {
        window.finishPDFOpen = () => send.call(this, message, ...args);
        return;
      }
      return send.call(this, message, ...args);
    };
    return (await import("./store.mjs")).loadState("last");
  });
  await pick("exercise");
  await page.waitForFunction(() => typeof window.finishPDFOpen === "function");
  await page.keyboard.press("r");
  const sheet = await page.locator("#sheet").boundingBox();
  await page.mouse.click(sheet.x + 120, sheet.y + 90);
  await page.locator("#editor").evaluate(input => {
    input.value = "Late observation";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    window.finishPDFOpen();
  });
  await page.waitForFunction(() => document.querySelector("#name").textContent === "exercise");
  assert(await page.locator("#editor").isHidden());
  const record = await page.evaluate(async id => (await import("./store.mjs")).loadRecord(id), outgoing);
  assert(record.book.objects.some(o => o.content.text?._0 === "Late observation"));
}

async function unusedPage(page) {
  await page.setInputFiles("#file", path.join(__dirname, "fixtures/exercise.pdf"));
  await page.locator("#sheet").waitFor();
  await page.click("#page");
  await page.evaluate(async () => {
    const { H, W } = await import("./engine.mjs");
    const view = document.querySelector("#view");
    view.scrollTop = 2 * H * view.clientWidth / W;
  });
  await page.waitForFunction(() => document.querySelector("#page").textContent === "Page 3");
  assert.equal(await page.locator('.page-thumb[aria-current="true"]').count(), 0,
    "An unused sheet must not select the last used page");
  assert(await page.locator('[data-action="delete"]').isDisabled());
  assert(await page.locator('[data-action="up"]').isDisabled());
  await page.getByRole("button", { name: "Add this page", exact: true }).click();
  assert.equal(await page.locator('.page-thumb[aria-current="true"]').getAttribute("data-page"), "2");
  await page.click("#undo");
  assert.equal(await page.locator(".page-thumb").count(), 2);
  await page.getByRole("button", { name: "Go to page 2", exact: true }).click();
  assert(await page.locator('[data-action="delete"]').isEnabled());
}

async function staleView(page) {
  await page.setInputFiles("#file", path.join(__dirname, "../docs/examples/Series circuit.gridnote"));
  await page.waitForFunction(() => document.querySelector("#name").textContent === "Series circuit");
  // A backup can predate the last selected object or the last edited table row.
  const id = await page.evaluate(async () => (await import("./store.mjs")).loadState("last"));
  async function resume(staleCell) {
    await page.reload();
    await page.locator("#continue").waitFor();
    await page.evaluate(async ({id, staleCell}) => {
      const s = await import("./store.mjs");
      const table = (await s.loadRecord(id)).book.objects.find(o => o.table);
      const view = { tool: "selector", selection: ["removed-object"] };
      if (staleCell) Object.assign(view, { editing: table.id, cell: table.table.cells.length + 1 });
      localStorage.setItem("gridnote-view-" + id, JSON.stringify(view));
    }, { id, staleCell });
    await page.click("#continue");
    await page.locator("#sheet").waitFor();
  }
  await resume(false);
  assert(await page.locator("#selection").isHidden(), "Removed objects cannot be selected after recovery");
  await resume(true);
  assert(await page.locator("#editor").isHidden(), "A removed table cell cannot receive typing after recovery");
  const valid = await page.evaluate(async id => {
    const s = await import("./store.mjs");
    const t = (await s.loadRecord(id)).book.objects.find(o => o.table).table;
    return t.cells.length === t.rows * t.columns;
  }, id);
  assert(valid);
}

async function keyboardActions(page) {
  await page.click("#new");
  await page.locator("#page").focus();
  await page.keyboard.press("Space");
  assert.equal(await page.locator("#page").getAttribute("aria-expanded"), "true",
    "Space activates a focused page button");
  await page.keyboard.press("r");
  const sheet = await page.locator("#sheet").boundingBox();
  await page.mouse.click(sheet.x + 100, sheet.y + 80);
  await page.fill("#editor", "Saved mid-sentence");
  const handled = await page.locator("#editor").evaluate(el => !el.dispatchEvent(new KeyboardEvent("keydown", {
    key: "s", code: "KeyS", ctrlKey: true, bubbles: true, cancelable: true,
  })));
  assert(handled, "Save from inside a note must not open the browser's Save Page dialog");
  assert(await page.locator("#editor").isVisible());
  await page.locator("#editor").press("Control+p");
  await page.locator("#pdfmodal[open]").waitFor({ timeout: 4000 });
  await page.click("#pdfclose");
  await waitForStoredValue(page, async () => {
    const s = await import("./store.mjs");
    return (await s.loadRecord(await s.loadState("last")))?.book.objects.some(o => o.content.text?._0 === "Saved mid-sentence");
  });
}

async function previewClipboard(page) {
  await page.click("#new");
  await page.click("#preview");
  await page.locator("#pdfmodal[open]").waitFor();
  const intercepted = await page.evaluate(() => {
    const data = new DataTransfer();
    data.setData("text/plain", "Pasted while reading a PDF");
    const event = new Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(event, "clipboardData", { value: data });
    document.querySelector("#pdfclose").dispatchEvent(event);
    return event.defaultPrevented;
  });
  assert.equal(intercepted, false, "Preview must leave the notebook clipboard handlers inactive");
  await page.click("#pdfclose");
  assert(await page.locator("#undo").isDisabled(), "Preview must not add an undoable notebook edit");
}

async function exportWhileSwitching(page) {
  await page.setInputFiles("#file", path.join(__dirname, "fixtures/exercise.pdf"));
  await page.waitForFunction(() => document.querySelector("#name").textContent === "exercise");
  // Hold PDF creation after Export captures the original notebook.
  await page.evaluate(async () => {
    const { PDFDocument } = await import("./vendor/pdf-lib.mjs");
    const create = PDFDocument.create;
    PDFDocument.create = async function(...args) {
      PDFDocument.create = create;
      await new Promise(resolve => { window.continueExport = resolve; });
      return create.apply(this, args);
    };
  });
  await page.click("#export");
  await page.waitForFunction(() => !!window.continueExport);
  await page.click("#files");
  await page.locator("#popover").getByRole("button", { name: "New notebook", exact: true }).click();
  await page.waitForFunction(() => document.querySelector("#name").textContent === "Untitled Notebook");
  const [file] = await Promise.all([
    page.waitForEvent("download", { timeout: 10000 }),
    page.evaluate(() => window.continueExport()),
  ]);
  assert.equal(file.suggestedFilename(), "exercise - Annotated.pdf");
  const bytes = (await require("node:fs/promises").readFile(await file.path())).toString("base64");
  assert.equal(await page.evaluate(async b64 => {
    const { PDFDocument } = await import("./vendor/pdf-lib.mjs");
    return (await PDFDocument.load(b64)).getPageCount();
  }, bytes), 2);
}

async function imagesWhileSwitching(page) {
  await page.click("#new");
  await page.click("#files");
  await page.locator("#popover").getByRole("button", { name: "Rename notebook…" }).click();
  await page.getByRole("textbox", { name: "Notebook name" }).fill("Original diagrams");
  await page.getByRole("button", { name: "Save name" }).click();
  const original = await waitForStoredValue(page, async () => {
    const s = await import("./store.mjs");
    const info = await s.lastNotebookInfo();
    return info?.title === "Original diagrams" && info.id;
  });
  // Delay the first of two images to force a notebook switch during decoding.
  await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 16;
    const png = await new Promise(resolve => canvas.toBlob(resolve, "image/png"));
    const decode = HTMLImageElement.prototype.decode;
    HTMLImageElement.prototype.decode = async function() {
      HTMLImageElement.prototype.decode = decode;
      await new Promise(resolve => { window.continueImage = resolve; });
      return decode.call(this);
    };
    const files = new DataTransfer();
    for (const name of ["one.png", "two.png"]) files.items.add(new File([png], name, { type: "image/png" }));
    const picker = document.querySelector("#imagefile");
    picker.files = files.files;
    picker.dispatchEvent(new Event("change"));
  });
  await page.waitForFunction(() => !!window.continueImage);
  await page.click("#files");
  await page.locator("#popover").getByRole("button", { name: "New notebook", exact: true }).click();
  await page.evaluate(() => window.continueImage());
  await waitForStoredValue(page, async id => {
    const s = await import("./store.mjs");
    const last = await s.loadState("last");
    return last && last !== id && (await s.loadRecord(last))?.title === "Untitled Notebook"
      && document.querySelector("#name").textContent === "Untitled Notebook"
      && document.querySelector("#saved").textContent === "Saved";
  }, original);
  const counts = await page.evaluate(async id => {
    const s = await import("./store.mjs");
    const count = async key => (await s.loadRecord(key)).book.objects.filter(o => o.content.image).length;
    return [await count(id), await count(await s.loadState("last"))];
  }, original);
  assert.deepEqual(counts, [2, 0], "both images belong to the notebook where the import began");
}

async function backupRecovery(page) {
  await page.click("#new");
  await waitForStoredValue(page, async () => !!await (await import("./store.mjs")).lastNotebookInfo());
  const id = await page.evaluate(async () => {
    const s = await import("./store.mjs");
    const id = await s.loadState("last");
    const { book } = await s.loadRecord(id);
    await s.saveRecord({ ...book, revision: 8 }, "Lab notes", book.revision);
    await s.saveRecord({ ...book, revision: 9 }, "Lab notes", 8);
    return id;
  });
  // Simulate a damaged latest record, followed later by a missing latest record.
  async function damage(remove) {
    await page.evaluate(async ({ id, remove }) => {
      const db = await new Promise((resolve, reject) => {
        const req = indexedDB.open("gridnote-notebooks");
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
      try {
        await new Promise((resolve, reject) => {
          const tx = db.transaction("books", "readwrite"), books = tx.objectStore("books");
          tx.oncomplete = resolve;
          tx.onabort = () => reject(tx.error);
          if (remove) books.delete(id);
          else {
            const req = books.get(id);
            req.onsuccess = () => books.put({ ...req.result, book: { ...req.result.book, version: -1 } }, id);
          }
        });
      } finally { db.close(); }
    }, { id, remove });
  }
  await damage(false);
  await page.reload();
  await page.click("#continue");
  await page.waitForSelector("#notice");
  await page.waitForFunction(() => document.querySelector("#saved").textContent === "Saved");
  const restored = await page.evaluate(async id => {
    const s = await import("./store.mjs");
    const { book, title } = await s.loadRecord(id);
    let staleRejected = false;
    try { await s.saveRecord({ ...book, revision: 11 }, "Stale window", 9); }
    catch (error) { staleRejected = /another window/.test(error.message); }
    return { revision: book.revision, title, staleRejected };
  }, id);
  assert.deepEqual(restored, { revision: 10, title: "Lab notes", staleRejected: true });
  await damage(true);
  await page.reload();
  await page.click("#continue");
  await page.waitForSelector("#sheet");
  await page.waitForFunction(() => document.querySelector("#saved").textContent === "Saved");
  assert.equal(await page.locator("#name").textContent(), "Lab notes");
  assert.equal(await page.evaluate(async id => (await (await import("./store.mjs")).loadRecord(id)).book.revision, id), 11);

}

(async () => {
  const engine = process.env.ENGINE || "chromium";
  const browser = await { chromium, webkit, firefox }[engine].launch(
    engine === "chromium" && process.env.BROWSER_BIN ? { executablePath: process.env.BROWSER_BIN } : {});
  try {
    const failures = [];
    for (const check of [editHistory, lastPage, inheritedPaper, backupRecovery, editDuringPDFOpen, unusedPage, staleView, keyboardActions, previewClipboard, exportWhileSwitching, imagesWhileSwitching]) {
      const page = await browser.newPage({ viewport: { width: 1024, height: 768 } });
      try {
        await page.goto(process.env.GRIDNOTE_URL);
        await check(page);
        console.log("PASS", engine, check.name);
      } catch (error) {
        failures.push(check.name + ": " + error.message);
      } finally { await page.close(); }
    }
    assert.deepEqual(failures, []);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
