const { chromium } = require("playwright"),
  assert = require("node:assert/strict"),
  path = require("node:path");
(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.BROWSER_BIN,
    headless: true,
    args: ["--no-first-run"],
  });
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    userAgent:
      "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 2,
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  // A deterministic rear-camera fixture exercises the complete camera, crop and placement UI.
  await page.addInitScript(() => {
    const capture = navigator.mediaDevices.getUserMedia.bind(
      navigator.mediaDevices,
    );
    navigator.mediaDevices.getUserMedia = async (opts) => {
      window.requestedFacing = opts.video.facingMode.exact;
      if (!opts.video) return capture(opts);
      const c = document.createElement("canvas");
      c.width = 1000;
      c.height = 700;
      const cx = c.getContext("2d");
      cx.fillStyle = "white";
      cx.fillRect(0, 0, 1000, 700);
      cx.font = "36px sans-serif";
      cx.fillStyle = "black";
      cx.fillText("Engineering exercise", 60, 70);
      const stream = c.captureStream(5);
      window.testCamera = stream;
      return stream;
    };
  });
  await page.goto(process.env.GRIDNOTE_URL || "http://127.0.0.1:8793/");
  assert.equal(await page.locator("#detected-device").isVisible(), false);
  await page.tap("#new");
  await page.waitForSelector("#sheet");
  const s = page.locator("#sheet");
  const r = await s.boundingBox();
  async function ptr(type, x, y, id = 1, pointerType = "touch", buttons = 1) {
    await s.dispatchEvent(type, {
      pointerId: id,
      pointerType,
      clientX: r.x + x,
      clientY: r.y + y,
      button: 0,
      buttons,
      pressure: 0.6,
      isPrimary: true,
      bubbles: true,
    });
  }
  await ptr("pointerdown", 60, 80);
  await ptr("pointermove", 130, 110);
  await ptr("pointerup", 130, 110, 1, "touch", 0);
  const wait = () => page.waitForTimeout(350),
    book = () =>
      page.evaluate(async () => {
        const s = await import("./store.mjs");
        return (await s.loadRecord(await s.loadState("last"))).book;
      });
  await wait();
  assert.equal((await book()).objects.length, 1);
  await ptr("pointerdown", 105, 146, 3, "pen");
  await ptr("pointerup", 105, 146, 3, "pen", 0);
  await wait();
  const count = (await book()).objects.length;
  await ptr("pointerdown", 130, 220);
  await ptr("pointermove", 130, 120);
  await ptr("pointerup", 130, 120, 1, "touch", 0);
  await wait();
  assert.equal((await book()).objects.length, count);
  assert((await page.locator("#view").evaluate((e) => e.scrollTop)) > 10);
  await page.locator("#view").evaluate((v) => v.scrollTo(0, 640));
  await wait();
  const anchor = await page.locator("#page").textContent();
  await page.tap("#addimage");
  await page.getByRole("button", { name: "Take photo…" }).tap();
  await page.getByRole("button", { name: "Capture", exact: true }).waitFor();
  await page.waitForFunction(
    () => !!document.querySelector("video")?.videoWidth,
  );
  assert.equal(
    await page.evaluate(() => window.requestedFacing),
    "environment",
  );
  await page.getByRole("button", { name: "Capture", exact: true }).tap();
  const crop = page.locator(".crop-rect"),
    box = await crop.boundingBox();
  // Dispatch trusted mouse events too so pointer capture has a live pointer.
  await page.mouse.move(box.x + 4, box.y + 4);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.17, box.y + box.height * 0.15, {
    steps: 5,
  });
  await page.mouse.up();
  await page.getByRole("button", { name: "Insert crop" }).tap();
  await wait();
  const result = await book(),
    image = result.objects.find((o) => o.content.image);
  assert(image);
  assert.equal(
    Math.floor(image.frame[0][1] / ((297 * 72) / 25.4)) + 1,
    Number(anchor.split(" ")[1]),
  );
  assert(
    await page.evaluate(() =>
      window.testCamera.getTracks().every((t) => t.readyState === "ended"),
    ),
  );
  assert.equal(await page.locator("#selection").isVisible(), true);
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth > innerWidth,
    ),
    false,
  );
  const dimensions = await page.evaluate(async (data) => {
    const im = new Image();
    im.src = "data:image/png;base64," + data;
    await im.decode();
    return [im.naturalWidth, im.naturalHeight];
  }, image.content.image._0);
  assert(
    dimensions[0] < 1000 && dimensions[1] < 700,
    "cropped image is smaller than the captured frame",
  );
  console.log(
    "PASS phone touch drawing, palm-safe navigation, rear camera constraint, crop, page-aware placement, released camera and compact layout",
  );
  assert.deepEqual(errors, []);
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
