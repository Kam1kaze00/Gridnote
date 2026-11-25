const { webkit } = require("playwright"),
  assert = require("node:assert/strict"),
  path = require("node:path");
(async () => {
  const b = await webkit.launch();
  try {
    const p = await b.newPage({ viewport: { width: 900, height: 860 } });
    const errors = [];
    p.on("pageerror", (e) => errors.push(e.message));
    await p.goto(process.env.GRIDNOTE_URL || "http://127.0.0.1:8793/");
    await p.getByLabel("Major", {exact:true}).selectOption("Chemistry");
    await p
      .locator("#file")
      .setInputFiles(path.resolve(__dirname, "fixtures/exercise.pdf"));
    await p.waitForSelector("#sheet");
    assert.equal(await p.locator("#subject-strip button").count(),6);
    const saved = async () => {
      await p.waitForTimeout(350);
      return p.evaluate(async () => {
        const s = await import("./store.mjs");
        return (await s.loadRecord(await s.loadState("last"))).book;
      });
    };
    await p.getByRole("button",{name:"Periodic table",exact:true}).click();
    const f = p.frameLocator(".subject-frame");
    await f.getByRole("textbox", { name: "Find an element" }).fill("79");
    assert.match(await f.locator("#result").innerText(), /Gold \(Au\)/);
    await f.getByRole("button", { name: "Insert in notebook" }).click();
    assert(
      (await saved()).objects.some((o) => o.content.text?._0.includes("Gold")),
    );
    await p.click("#page");
    await p.getByRole("button", { name: "Insert page after" }).click();
    let n = await saved();
    assert.deepEqual(n.sourcePageMap, [0, -1, 1]);
    assert.equal(n.minimumPages, 3);
    await p.getByRole("button", { name: "Go to page 1", exact: true }).click();
    await p.getByRole("button", { name: "Move page later" }).click();
    n = await saved();
    assert.deepEqual(n.sourcePageMap, [-1, 0, 1]);
    assert(n.objects[0].frame[0][1] > 841);
    const beforeClear = n;
    const clear = p.getByRole("button", { name: "Clear typed text on this page", exact: true });
    await clear.click();
    n = await saved();
    assert.equal(n.objects.length, 0);
    assert.deepEqual(n.sourcePageMap, beforeClear.sourcePageMap);
    assert.equal(n.sourcePDF, beforeClear.sourcePDF);
    await clear.click();
    await p.click("#undo");
    assert.deepEqual((await saved()).objects, beforeClear.objects);
    await p.click("#redo");
    assert.equal((await saved()).objects.length, 0);
    await p.click("#undo");
    await p.getByRole("button", { name: "Delete selected page" }).click();
    assert.equal((await saved()).objects.length, 0);
    await p.click("#undo");
    n = await saved();
    assert(n.objects[0].content.text._0.includes("Gold"));
    await p.reload();
    await p.click("#continue");
    await p.waitForSelector("#subject-strip");
    await p.click("#preview");
    await p.waitForFunction(() =>
      document.querySelector("#pdfcount")?.textContent.includes("/ 3"),
    );
    await p.click("#pdfclose");
    const scan = await p.evaluate(async () => {
      const { scanProblems } = await import("./study.mjs"),
        { blank } = await import("./engine.mjs");
      const c = document.createElement("canvas");
      c.width = 1000;
      c.height = 155;
      const g = c.getContext("2d");
      g.fillStyle = "white";
      g.fillRect(0, 0, c.width, c.height);
      g.fillStyle = "black";
      g.font = "34px Arial";
      g.fillText("A cart travels 24 meters in 3 seconds.", 24, 56);
      g.fillText("What is its average speed?", 24, 106);
      const n = blank();
      n.objects = [
        {
          id: crypto.randomUUID(),
          frame: [
            [40, 80],
            [480, 75],
          ],
          content: { image: { _0: c.toDataURL().split(",")[1] } },
        },
      ];
      const r = await scanProblems(n, null, 0);
      return r.found.map((x) => ({
        text: x.text,
        crop: !!x.crop?.(),
        review: x.review,
      }));
    });
    assert(
      scan.some(
        (x) => x.crop && x.review && /24/.test(x.text) && /speed/i.test(x.text),
      ),
      JSON.stringify(scan),
    );
    assert.deepEqual(errors, []);
    console.log(
      "PASS optional major, searchable periodic table, insert result, PDF page insertion/reordering/deletion/undo, three-page preview and two-line photographed word problem.",
    );
  } finally {
    await b.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
