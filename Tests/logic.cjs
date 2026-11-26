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
  await page.waitForFunction(async () => {
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
  await page.waitForFunction(async () => (await (await import("./store.mjs")).lastNotebookInfo())?.title === "exercise");
  await pick("New notebook");
  await page.waitForFunction(async () => (await (await import("./store.mjs")).lastNotebookInfo())?.title === "Untitled Notebook");
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

async function backupRecovery(page) {
  await page.click("#new");
  await page.waitForFunction(async () => !!await (await import("./store.mjs")).lastNotebookInfo());
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
    for (const check of [editHistory, lastPage, inheritedPaper, backupRecovery, editDuringPDFOpen]) {
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
