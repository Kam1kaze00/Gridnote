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
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(process.env.GRIDNOTE_URL);
    await page.click("#new");
    const writer = page.getByRole("button", { name: "Writer", exact: true });
    const panel = page.locator("#popover");
    const options = async () => {
      await writer.click();
      await panel.getByRole("heading", { name: "Writer" }).waitFor();
    };
    const tip = async (name) => {
      const button = panel.getByRole("button", { name, exact: true });
      await button.click();
      assert.equal(await button.getAttribute("aria-pressed"), "true");
      assert.equal(await writer.locator(".tool-name").textContent(), "Writer");
    };
    const slider = (label, value) =>
      panel
        .getByRole("slider", { name: label, exact: true })
        .fill(String(value));
    const sheet = page.locator("#sheet");
    let count = 0;
    async function draw(pressures, liftOffset = 0) {
      await sheet.evaluate((canvas, {pressures, liftOffset}) => {
        const rect = canvas.getBoundingClientRect(),
          now = performance.now();
        function pen(type, i, pressure) {
          const event = new PointerEvent(type, {
            bubbles: true,
            pointerType: "pen",
            pointerId: 9,
            isPrimary: true,
            button: type === "pointermove" ? -1 : 0,
            buttons: type === "pointerup" ? 0 : 1,
            pressure,
            clientX: rect.left + 70 + i * 10,
            clientY: rect.top + 100,
          });
          Object.defineProperty(event, "timeStamp", { value: now + i * 25 });
          canvas.dispatchEvent(event);
        }
        pressures.forEach((v, i) =>
          pen(i === 0 ? "pointerdown" : "pointermove", i, v),
        );
        pen("pointerup", pressures.length - 1 + liftOffset, 0);
      }, {pressures, liftOffset});
      ++count;
      for (let i = 0; i < 80; i++) {
        const radii = await page.evaluate(async (n) => {
          const store = await import("./store.mjs");
          const saved = await store.loadRecord(await store.loadState("last"));
          if (saved?.book.objects.length === n)
            return saved.book.objects
              .at(-1)
              .content.ink._0.map((p) => p.radius);
        }, count);
        if (radii) return radii;
        await page.waitForTimeout(50);
      }
      throw Error("Stroke " + count + " was not saved");
    }
    await options();
    await tip("Fineliner");
    await slider("Width", 1.1);
    // First contact identifies an external pen after a mouse chose the tool.
    assert(
      (await draw([0.1, 0.8, 1])).every((x) => Math.abs(x - 0.55) < 0.00001),
    );
    const spans = {};
    for (const name of ["Pen", "Brush", "Fineliner", "Gel", "Fountain", "Pencil"]) {
      await options();
      await tip(name);
      const original = Number(
        await panel.getByLabel("Width", { exact: true }).inputValue(),
      );
      assert.equal(original, { Pen: 1.5, Brush: 2, Fineliner: 1.1, Gel:2.5, Fountain:4.2, Pencil:2.1 }[name]);
      await slider("Width", 3);
      const radii = await draw([0.1, 0.4, 0.8, 1]);
      spans[name] = Math.max(...radii) - Math.min(...radii);
    }
    assert(
      spans.Pen > 0.2 &&
        spans.Brush > 3 * spans.Pen &&
        spans.Fineliner < 0.00001,
    );
    assert(spans.Gel < spans.Pen && spans.Pencil > spans.Fountain);
    const tips = await page.evaluate(async () => {
      const {loadRecord,loadState} = await import("./store.mjs");
      const {book} = await loadRecord(await loadState("last"));
      return book.objects.slice(-3).map(o => o.inkNib);
    });
    assert.deepEqual(tips,["Gel","Fountain","Pencil"].map(tip => ({tip,width:3})));
    const density = await page.evaluate(async () => {
      const {loadState, loadRecord} = await import("./store.mjs");
      const {paintObject} = await import("./render.mjs");
      const {makeInk, transform} = await import("./engine.mjs");
      const {erasePart} = await import("./eraser.mjs");
      const {book} = await loadRecord(await loadState("last"));
      const pen = book.objects.find(o => o.ballpointWidth === 3);
      const points = pen.content.ink._0, color = pen.content.ink._1;
      function coverage(radius) {
        const sample = makeInk([{position: [2, 2], radius}], color);
        sample.ballpointWidth = pen.ballpointWidth;
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 160;
        const ctx = canvas.getContext("2d");
        ctx.scale(40, 40);
        paintObject(ctx, sample);
        const {data} = ctx.getImageData(0, 80, 160, 1);
        let sum = 0;
        for (let i = 3; i < data.length; i += 4) sum += data[i] / 255;
        return sum / (80 * radius);
      }
      const mid = points[Math.floor(points.length / 2)].position;
      const parts = erasePart(pen, mid, mid, 0.4);
      return {light: coverage(points[0].radius), heavy: coverage(points.at(-1).radius),
        scaled: transform(pen, [0,0], 2, 0, 0).ballpointWidth,
        pieces: parts.map(o => o.ballpointWidth)};
    });
    assert(density.heavy > density.light + 0.33, "pressure darkens the track");
    assert.equal(density.scaled, 6);
    assert.deepEqual(density.pieces, [3, 3]);
    await options();
    await tip("Brush");
    await slider("Width", 4);
    const moving = await draw([0.9, 0.9], 1);
    assert(moving.at(-1) < moving[0] * 0.5, "moving brush lift tapers");
    const sameLift = await draw([0.7, 0.7, 0.7, 0.7]);
    assert(sameLift[0] < Math.max(...sameLift) * 0.4 && sameLift.at(-1) < Math.max(...sameLift) * 0.16,
      "a normal pointerup at the last sampled position finishes a pointed brush stroke");
    const dot = await draw([0.9]);
    assert(dot.length === 1 && dot[0] > 3, "a stationary brush dot retains its weight");
    await options();
    await slider("Pressure response", 0.5);
    const [soft] = await draw([0.3]);
    await options();
    await slider("Pressure response", 2);
    const [firm] = await draw([0.3]);
    assert(soft > 2 * firm);
    await options();
    await panel.getByLabel("Use pen pressure").uncheck();
    assert((await draw([0.05, 0.95])).every((r) => r === 2));
    await options();
    await tip("Pen");
    assert.equal(
      Number(await panel.getByLabel("Width", { exact: true }).inputValue()),
      3,
    );
    await slider("Width", 1);
    await slider("Ink flow", 0.25);
    assert((await draw([0.5, 0.5])).every(r => r === 0.5));
    await options();
    await slider("Width", 4);
    await slider("Ink flow", 1);
    assert((await draw([0.5, 0.5])).every(r => r === 2));
    const renderedFlow = await page.evaluate(async () => {
      const {loadState, loadRecord} = await import("./store.mjs");
      const {paintObject} = await import("./render.mjs");
      const {book} = await loadRecord(await loadState("last"));
      const [light, dark] = book.objects.slice(-2);
      function coverage(stroke) {
        const canvas = document.createElement("canvas");
        canvas.width = 180; canvas.height = 80;
        const ctx = canvas.getContext("2d");
        ctx.scale(8, 8);
        const [x, y] = stroke.content.ink._0[0].position;
        ctx.translate(3-x, 4-y);
        paintObject(ctx, stroke);
        const bytes = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
        let sum = 0;
        for (let i=3; i<bytes.length; i+=4) sum += bytes[i];
        return sum;
      }
      return [light.opacity, dark.opacity ?? 1, coverage(light), coverage({...light,opacity:1})];
    });
    assert.deepEqual(renderedFlow.slice(0,2), [0.25,1]);
    assert(renderedFlow[2] > 0 && renderedFlow[3] > 2*renderedFlow[2],
      "Pen flow visibly changes the finished stroke even when pressure is off");
    await options();
    await slider("Ink flow", 0.55);
    await page.reload();
    await page.click("#continue");
    await options();
    assert.equal(
      await panel
        .getByRole("button", { name: "Pen", exact: true })
        .getAttribute("aria-pressed"),
      "true",
    );
    assert.equal(Number(await panel.getByLabel("Ink flow", {exact:true}).inputValue()), 0.55);
    await tip("Brush");
    assert.equal(
      Number(await panel.getByLabel("Width", { exact: true }).inputValue()),
      4,
    );
    await panel.getByRole("button", { name: "Restore tool defaults" }).click();
    assert.equal(
      Number(await panel.getByLabel("Width", { exact: true }).inputValue()),
      2,
    );
    const detail = await page.evaluate(async () => {
      const {sampledRadius} = await import("./devices.mjs");
      const {fittedInk} = await import("./engine.mjs");
      const p = {nib:"Brush",width:2,pressure:1,smoothing:0.8,usePressure:true};
      const sample = tilt => sampledRadius(p,0.6,null,3,0.01,false,true,tilt);
      const raw = [[0,0],[3,0.14],[6,0]].map(position => ({position,radius:0.5}));
      const fitted = nib => fittedInk(raw,{...p,nib},[0,0.004,0.008]);
      const midY = points => points[Math.floor(points.length/2)].position[1];
      return [sample(0.8)/sample(0), midY(fitted("Fineliner")), midY(fitted("Pen"))];
    });
    assert(detail[0] > 1.25 && detail[1] < detail[2], "brush tilt and fineliner micro-stabilization");
    // Inspect the ink deposited on an actual exported page at the same width and color.
    const marks = await page.evaluate(async () => {
      const {blank,W,makeInk} = await import("./engine.mjs");
      const {makePDF,readPDF,pdfBitmap} = await import("./render.mjs");
      const book = blank();
      book.defaultPaper = {ruling:"Whiteboard",tint:"White"};
      function stroke(tip,y,slope=0) {
        const points = [0,1].map(t=>({position:[90+t*30, y+t*slope],radius:3}));
        const o = makeInk(points,{r:0,g:0,b:0});
        o.inkNib = {tip,width:4};
        book.objects.push(o);
      }
      stroke("Gel",50);
      stroke("Pencil",80);
      stroke("Fountain",116,30);
      stroke("Fountain",178,-30);
      const zoom = 5, doc = await readPDF(await makePDF(book));
      const bitmap = await pdfBitmap(doc,0,W*zoom);
      const ctx = bitmap.getContext("2d");
      function scan(y,w,h) {
        const bytes=ctx.getImageData(100*zoom,Math.round(y*zoom),w,h).data;
        const gray=[];
        for(let i=0;i<bytes.length;i+=4) gray.push(bytes[i]);
        return gray;
      }
      const gel=scan(49.5,60,5), pencil=scan(79.5,60,5);
      const coverage = (y, slope) => {
        // The centreline at x=100 lies ten points along the diagonal.
        const xx=100*zoom, yy=Math.round((y+10*slope)*zoom);
        const data=ctx.getImageData(xx,yy-40,1,80).data;
        let ink=0;
        for(let i=0;i<data.length;i+=4) ink+=(255-data[i])/255;
        return ink;
      };
      return {gel:Math.max(...gel), graphiteContrast:Math.max(...pencil)-Math.min(...pencil),
        narrow:coverage(116,1), broad:coverage(178,-1)};
    });
    assert(marks.gel < 10 && marks.graphiteContrast > 45, "gel is opaque and the printed pencil shows paper tooth");
    assert(marks.broad > 1.7*marks.narrow, "a broad fountain nib changes the printed width with direction");
    assert.deepEqual(errors, []);
    console.log(
      "PASS",
      engine,
      "Writer tip selection, distinct pressure and widths, curve, mouse-to-pen handoff, persistence and reset",
    );
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
