import { W, H, bounds, corners, overlaps, kind } from "./engine.mjs";
export function intersection(a, b) {
  const [[x, y], [w, h]] = a,
    [[u, v], [p, q]] = b,
    ox = Math.max(x, u),
    oy = Math.max(y, v);
  return [
    [ox, oy],
    [
      Math.max(0, Math.min(x + w, u + p) - ox),
      Math.max(0, Math.min(y + h, v + q) - oy),
    ],
  ];
}
export function padded([[x, y], [w, h]], d) {
  return [
    [x - d, y - d],
    [w + 2 * d, h + 2 * d],
  ];
}
export function inkRegions(objects, area) {
  const groups = [];
  for (const o of objects
    .filter((o) => kind(o) === "ink" && !o.instrument)
    .sort((a, b) => a.frame[0][0] - b.frame[0][0])) {
    const f = intersection(o.frame, area),
      [[, y], [, h]] = f;
    const i = groups.findLastIndex(
      (g) =>
        Math.abs(g[0][1] + g[1][1] / 2 - y - h / 2) <=
          Math.max(4, Math.max(g[1][1], h) * 0.68) &&
        overlaps(padded(g, Math.max(10, Math.min(26, g[1][1]))), f),
    );
    if (i < 0) groups.push(f);
    else groups[i] = bounds([...corners(groups[i]), ...corners(f)]);
  }
  return groups.filter((f) => f[1][0] >= 5 && f[1][1] >= 2);
}
export function cropImage(canvas, frame, scale, box) {
  const [[x, y], [w, h]] = intersection(padded(box, 3), frame);
  if (w <= 0 || h <= 0) return null;
  const c = document.createElement("canvas"),
    k = Math.min(scale, 1500 / Math.max(w, h));
  c.width = Math.max(1, Math.ceil(w * k));
  c.height = Math.max(1, Math.ceil(h * k));
  c.getContext("2d").drawImage(
    canvas,
    (x - frame[0][0]) * scale,
    (y - frame[0][1]) * scale,
    w * scale,
    h * scale,
    0,
    0,
    c.width,
    c.height,
  );
  return c;
}
export async function pdfLines(source, book, n) {
  const page = await source.getPage((book.sourcePageMap?.[n] ?? n) + 1),
    unit = page.getViewport({ scale: 1 }),
    scale = Math.min(
      book.originalPDFScale ? 1 : Infinity,
      W / unit.width,
      H / unit.height,
    );
  const vp = page.getViewport({ scale }),
    left = (W - vp.width) / 2,
    top = n * H + (H - vp.height) / 2,
    lines = [];
  let text = "",
    rects = [];
  const flush = () => {
    if (text.trim() && rects.length)
      lines.push({ text: text.trim(), frame: bounds(rects), code: false });
    text = "";
    rects = [];
  };
  for (const item of (await page.getTextContent()).items) {
    if (typeof item.str !== "string" || !item.transform) continue;
    const [a, b, , , x, y] = item.transform,
      len = Math.hypot(a, b) || 1,
      ux = a / len,
      uy = b / len;
    const pts = [
      [0, -0.2],
      [1, -0.2],
      [1, 0.85],
      [0, 0.85],
    ].map(([u, v]) => {
      const [cx, cy] = vp.convertToViewportPoint(
        x + ux * u * item.width - uy * v * item.height,
        y + uy * u * item.width + ux * v * item.height,
      );
      return [left + cx, top + cy];
    });
    rects.push(...pts);
    text += item.str;
    if (item.hasEOL) flush();
  }
  flush();
  return lines;
}
