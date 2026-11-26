const waitForStoredValue = require("./wait-for-storage.cjs");
const { chromium, webkit, firefox } = require("playwright");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const http = require("node:http");
// Playwright WebKit's offline emulation rejects service-worker navigation.
// Disconnect a real test origin to exercise cached navigation on that engine.
async function testOrigin(target) {
  const proxy = http.createServer((req, res) => {
    const up = http.request(
      new URL(req.url, target),
      { method: req.method },
      (result) => {
        res.writeHead(result.statusCode, result.headers);
        result.pipe(res);
      },
    );
    res.once("close", () => up.destroy());
    up.on("error", () => {
      if (res.destroyed || res.writableEnded) return;
      res.writeHead(502);
      res.end();
    });
    req.pipe(up);
  });
  await new Promise((r) => proxy.listen(0, "127.0.0.1", r));
  return {
    url: "http://127.0.0.1:" + proxy.address().port + "/",
    close() {
      if (proxy.listening) {
        proxy.close();
        proxy.closeAllConnections();
      }
    },
  };
}

async function main() {
  const name = process.env.ENGINE || "chromium",
    browser = await { chromium, webkit, firefox }[name].launch({
      headless: true,
      ...(name === "chromium" && process.env.BROWSER_BIN
        ? { executablePath: process.env.BROWSER_BIN }
        : {}),
    });
  const target = process.env.GRIDNOTE_URL || "http://127.0.0.1:8793/";
  const proxy = name === "webkit" ? await testOrigin(target) : null;
  try {
    if (name === "chromium") {
      const fresh = await browser.newContext();
      try {
        const asset = "**/eng.traineddata.gz";
        await fresh.route(asset, route => route.fulfill({ status: 503, body: "Offline" }));
        const firstVisit = await fresh.newPage();
        firstVisit.setDefaultTimeout(30000);
        async function waitStatus(pattern) {
          try {
            await firstVisit.waitForFunction(source =>
              new RegExp(source).test(document.querySelector("#offline-status")?.textContent), pattern);
          } catch (error) {
            const status = await firstVisit.locator("#offline-status").textContent();
            throw Error("Offline setup expected " + pattern + ", saw " + status, { cause: error });
          }
        }
        await firstVisit.goto(target);
        await waitStatus("Reopen online to retry");
        await fresh.unroute(asset);
        await firstVisit.reload();
        await waitStatus("Ready offline");
      } finally {
        await fresh.close();
      }
    }
    const context = await browser.newContext({
      viewport: { width: 1100, height: 760 },
      acceptDownloads: true,
    });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.setDefaultTimeout(8000);
    page.setDefaultNavigationTimeout(45000);
    await page.addInitScript(() => {
      Object.defineProperty(navigator, "canShare", {
        value: (v) => v.files?.[0]?.type === "application/pdf",
        configurable: true,
      });
      Object.defineProperty(navigator, "share", {
        value: async (v) => {
          window.sharedBytes = Array.from(
            new Uint8Array(await v.files[0].arrayBuffer()),
          );
        },
        configurable: true,
      });
    });
    await page.goto(proxy?.url || target, { waitUntil: "domcontentloaded" });
    await page.locator(".start-card").waitFor();
    const paper = await page.evaluate(async () => {
      const { blank, validate } = await import("./engine.mjs");
      const notebook = blank();
      notebook.defaultPaper = { ruling: "Dotted", tint: "Sage", stationery: "Pixelated" };
      notebook.pagePaper = { 0: { ruling: "Ruled", tint: "Ivory", cartoon: true } };
      const migrated = validate(notebook);
      return [migrated.defaultPaper, migrated.pagePaper[0]];
    });
    assert.deepEqual(paper, [{ ruling: "Dotted", tint: "Sage" }, { ruling: "Ruled", tint: "Ivory" }]);
    const rejectedPaper = await page.evaluate(async () => {
      const { blank, validate } = await import("./engine.mjs");
      return ["NaN", "-1", "100000"].every(index => {
        const notebook = blank();
        notebook.pagePaper = { [index]: { ruling: "Grid", tint: "White" } };
        try { validate(notebook); return false; } catch { return true; }
      });
    });
    assert(rejectedPaper, "damaged paper indexes are reported before replacing the current notebook");
    assert(!(await page.locator("#sheet").isVisible()));
    await page.click("#new");
    await waitForStoredValue(page, async () => Boolean(await (await import("./store.mjs")).lastNotebookInfo()));
    const lastSaved = await page.evaluate(async () => {
      const { loadState } = await import("./store.mjs");
      const transaction = IDBDatabase.prototype.transaction;
      IDBDatabase.prototype.transaction = function(stores, mode, ...args) {
        if (mode === "readwrite" && Array.isArray(stores) && stores.includes("assets"))
          throw new DOMException("Storage full", "QuotaExceededError");
        return transaction.call(this, stores, mode, ...args);
      };
      return loadState("last");
    });
    await page.click("#files");
    await page.getByRole("button", { name: "New notebook", exact: true }).click();
    await page.waitForFunction(() => document.querySelector("#saved").textContent === "Save error");
    await page.reload();
    await page.click("#continue");
    assert.equal(await page.evaluate(async () => (await import("./store.mjs")).loadState("last")), lastSaved);
    await page.waitForSelector("#tool-table");
    await page.click("#tool-brush");
    await page.getByRole("button", { name: "Fineliner", exact: true }).click();
    assert.equal(await page.locator("#tool-brush use").getAttribute("href"), "./assets/tools.svg#fineliner");
    await page.keyboard.press("Escape");
    await page.reload();
    assert(!(await page.locator("#sheet").isVisible()));
    await page.click("#continue");
    await page.waitForSelector("#sheet");
    const b = await page.locator("#sheet").boundingBox();
    const f = b.width / ((210 * 72) / 25.4);
    const point = (x, y) => [b.x + x * f, b.y + y * f];
    const tap = (x, y) => page.mouse.click(...point(x, y));
    async function drag(x, y, a, b) {
      await page.mouse.move(...point(x, y));
      await page.mouse.down();
      await page.mouse.move(...point(a, b), { steps: 7 });
      await page.mouse.up();
    }
    async function book() {
      await page.waitForTimeout(250);
      await page.waitForFunction(
        () => document.querySelector("#saved").textContent === "Saved",
      );
      return page.evaluate(async () => {
        const s = await import("./store.mjs");
        return (await s.loadRecord(await s.loadState("last"))).book;
      });
    }
    const tool = async (id) => {
      await page.click("#tool-" + id);
      await page.keyboard.press("Escape");
    };
    await tool("table");
    await drag(75, 80, 290, 163);
    let table = (await book()).objects[0];
    assert.equal(table.table.rows, 3);
    await page.click("#tool-selector");
    await page.getByLabel("Columns", { exact: true }).fill("4");
    await page.getByLabel("Columns", { exact: true }).press("Tab");
    await page.getByLabel("Header row").uncheck();
    for (const [label, value] of [["Rows","2"],["Width (pt)","250"],["Height (pt)","74"]]) {
      const field = page.getByLabel(label, {exact:true});
      await field.fill(value);
      await field.press("Tab");
    }
    await page.keyboard.press("Escape");
    table = (await book()).objects[0];
    assert.equal(table.table.columns, 4);
    assert.equal(table.table.header, false);
    assert.equal(table.table.rows, 2);
    assert.deepEqual(table.frame[1], [250,74]);
    await tool("table");
    await tap(90, 92);
    await page.locator("#editor").fill("Velocity");
    await book();
    await page.reload();
    await page.click("#continue");
    await page.waitForSelector("#editor");
    assert.equal(await page.locator("#editor").inputValue(), "Velocity");
    await page.keyboard.press("Control+Enter");
    assert.equal((await book()).objects[0].table.cells[0], "Velocity");
    await page.click("#tool-marker");
    await page.getByRole("slider", {name:"Width", exact:true}).fill("15");
    await page.getByRole("slider", {name:"Opacity", exact:true}).fill("0.5");
    await page.keyboard.press("Escape");
    await drag(70, 190, 170, 190);
    const marker = (await book()).objects.at(-1);
    assert.equal(marker.instrument, "marker");
    assert.equal(marker.opacity, 0.5);
    assert(marker.content.ink._0.every(p => p.radius === 7.5));
    await page.click("#tool-shapes");
    await page.getByRole("button", { name: "Arrow", exact: true }).click();
    await page.getByRole("slider", {name:"Line width"}).fill("4");
    await page.getByLabel("Constrain angles and proportions").check();
    await page.keyboard.press("Escape");
    await drag(200, 190, 255, 211);
    const shape = (await book()).objects.at(-1);
    assert.equal(shape.instrument, "shape");
    const [start, end] = shape.content.ink._0.map(p => p.position);
    const angle = Math.atan2(end[1]-start[1], end[0]-start[0]) * 12 / Math.PI;
    assert(Math.abs(angle - Math.round(angle)) < 0.00001);
    assert(shape.content.ink._0.every(p => p.radius === 2));
    await page.click("#tool-shapes");
    await page.getByRole("button", {name:"X–Y axes", exact:true}).click();
    assert.match(await page.locator("#tool-shapes use").getAttribute("href"), /#axes$/);
    await page.keyboard.press("Escape");
    await drag(360, 225, 270, 165);
    const axes = (await book()).objects.at(-1);
    assert.equal(axes.instrument, "shape");
    const [[ax, ay], [aw, ah]] = axes.frame;
    const center = [ax + aw/2, ay + ah/2];
    const vertices = axes.content.ink._0.map(p => p.position);
    assert(vertices.some(p => Math.hypot(p[0]-center[0], p[1]-center[1]) < 0.01));
    assert.equal(vertices[0][0], ax + 2); // Left end even for a reversed drag.
    await page.keyboard.press("Control+z");
    await page.click("#tool-text");
    await page.getByLabel("Insert code block").check();
    await page.getByRole("slider", {name:"Type size"}).fill("17");
    await page.getByRole("button", {name:"Right",exact:true}).click();
    await page.keyboard.press("Escape");
    await tap(70, 235);
    await page.locator("#editor").fill("return x * x;");
    await page.keyboard.press("Control+Enter");
    const code = (await book()).objects.at(-1);
    assert.equal(code.content.text._2, 17);
    assert.equal(code.alignment, "Right");
    assert.equal(code.codeStyle, true);
    await page.keyboard.press("w");
    await tap(84, 242);
    await page.click("#code-toggle");
    assert.equal((await book()).objects.at(-1).codeStyle, false);
    await page.click("#tool-text");
    await page.getByLabel("Insert code block").uncheck();
    await page.keyboard.press("Escape");
    await tap(75, 280);
    await page.locator("#editor").fill("2x + 3 = 11");
    await page.keyboard.press("Control+Enter");
    await book();
    await page.click("#solve");
    await page.waitForFunction(
      () => document.querySelector("#solve").textContent === "Solve",
      null,
      { timeout: 120000 },
    );
    await tap(86, 287);
    assert.match(await page.locator(".study-answer").innerText(), /x = 4/);
    const hasTutor = ["http://127.0.0.1:48765", "http://127.0.0.1:8765", "http://localhost:8765"]
      .includes(new URL(page.url()).origin);
    assert.equal(await page.getByRole("button", { name: "Ask AI", exact: true }).count(), Number(hasTutor));
    const actions = await page.locator(".study-actions button").evaluateAll(buttons =>
      buttons.map(b => { const r=b.getBoundingClientRect(); return [r.width,r.top,r.height]; }));
    assert(actions.every(a => a.every((v,i) => Math.abs(v-actions[0][i]) <= 1)));
    await page.evaluate(() => {
      Object.defineProperty(navigator, "clipboard", { configurable: true, value: {
        writeText: async text => {window.copiedExercise=text;},
        write: async items => {window.copiedExercise=await (await items[0].getType("text/plain")).text();},
      }});
    });
    const windows = context.pages().length;
    await page.getByRole("button",{name:"Copy",exact:true}).click();
    await page.waitForFunction(() => !!window.copiedExercise);
    assert.equal(await page.evaluate(() => window.copiedExercise), await page.getByLabel("Recognized exercise").inputValue());
    assert.equal(context.pages().length,windows);
    if (new URL(page.url()).origin === "http://127.0.0.1:48765") {
      await page.evaluate(() => {
        const fetchOriginal = window.fetch;
        window.tutorActions = [];
        window.fetch = async (url, options) => {
          if (url !== "./api/chatgpt") return fetchOriginal(url,options);
          const req = JSON.parse(options.body);
          window.tutorActions.push(req);
          return Response.json({connected: true, answer: req.action === "ask" ? "The worked answer is four." : undefined});
        };
      });
      await page.getByRole("button",{name:"Ask AI",exact:true}).click();
      await page.waitForFunction(() => document.querySelector(".study-answer")?.textContent==="The worked answer is four.");
      const requests = await page.evaluate(() => window.tutorActions);
      assert.deepEqual(requests.map(r=>r.action),["connect","ask"]);
      assert.equal(requests[1].text,await page.getByLabel("Recognized exercise").inputValue());
    }
    await page.keyboard.press("Escape");
    await page.click("#preview");
    await page.waitForSelector("#pdfcanvas");
    await page.click("#pdfshare");
    await page.waitForFunction(() => window.sharedBytes?.length > 100);
    const dl = page.waitForEvent("download");
    await page.click("#pdfsave");
    const bytes = await fs.readFile(await (await dl).path());
    const shared = await page.evaluate(() => window.sharedBytes);
    assert.deepEqual(bytes, Buffer.from(shared));
    await page.click("#pdfclose");
    await page.waitForFunction(() => document.getElementById("pdfcanvas").width === 0);
    await page.click("#preview");
    await page.waitForFunction(() => document.getElementById("pdfcanvas").width > 0);
    await page.keyboard.press("Escape");
    await page.waitForFunction(() => document.getElementById("pdfcanvas").width === 0);
    const recognition = await page.evaluate(async () => {
      const { scanProblems } = await import("./study.mjs"),
        { blank } = await import("./engine.mjs");
      const c = document.createElement("canvas");
      c.width = 700;
      c.height = 100;
      const g = c.getContext("2d");
      g.fillStyle = "white";
      g.fillRect(0, 0, 700, 100);
      g.fillStyle = "black";
      g.font = "40px Arial";
      g.fillText("12 + 6", 20, 60);
      const n = blank();
      n.objects = [
        {
          id: crypto.randomUUID(),
          frame: [
            [50, 60],
            [420, 60],
          ],
          content: { image: { _0: c.toDataURL().split(",")[1] } },
        },
      ];
      const result = await scanProblems(n, null, 0);
      return result;
    });
    assert(
      recognition.found.some(
        (p) => /12/.test(p.text) && GridAnswer(p.text) === "18",
      ),
      JSON.stringify(recognition),
    );
    function GridAnswer(s) {
      require("../web/solver.js");
      return globalThis.GridnoteSolve.solve(s)?.answer;
    }
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.waitForFunction(() =>
      Boolean(navigator.serviceWorker.controller),
    );
    await page.waitForFunction(() => document.querySelector("#offline-status").textContent === "Ready offline");
    if (proxy) proxy.close();
    else await context.setOffline(true);
    await page.reload();
    await page.click("#continue");
    await page.waitForSelector("#sheet");
    await page.evaluate(() => {
      IDBObjectStore.prototype.getAll = () => { throw new Error("Library unavailable"); };
    });
    await page.click("#files");
    await page.waitForFunction(() => document.querySelector("#offline-menu-status")?.textContent === "Ready offline");
    const backupDownload = page.waitForEvent("download");
    await page.getByRole("button", { name: "Download editable notebook" }).click();
    const backup = await backupDownload;
    const restored = JSON.parse(await fs.readFile(await backup.path(), "utf8"));
    assert(restored.objects.some((o) => o.table?.cells[0] === "Velocity"));
    await page.keyboard.press("Escape");
    assert(
      (await book()).objects.some((o) => o.table?.cells[0] === "Velocity"),
    );
    const guide = await context.newPage();
    await guide.goto(new URL("guide.html", page.url()).href);
    assert.equal(await guide.title(), "Gridnote Guide");
    await guide.close();
    assert.deepEqual(errors, []);
    if (!proxy) await context.setOffline(false);
    await context.close();
    console.log(
      "PASS " +
        name +
        " tables, cell autosave/reopen, shapes, highlighter, code, local solve, image OCR identical shared/exported PDF bytes and offline reopening.",
    );
  } finally {
    proxy?.close();
    await browser.close();
  }
}
main().then(() => process.exit(0)).catch((e) => {
  console.error(e);
  process.exit(1);
});
