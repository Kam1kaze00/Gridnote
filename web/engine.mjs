// Notebook measurements are PDF points, with the origin at the top left.
export const W = (210 * 72) / 25.4,
  H = (297 * 72) / 25.4,
  G = (5 * 72) / 25.4;
export const inks = [
  [0.11, 0.14, 0.17],
  [0.11, 0.33, 0.71],
  [0.05, 0.4, 0.33],
  [0.72, 0.19, 0.23],
  [0.42, 0.24, 0.66],
].map(([r, g, b]) => ({ r, g, b }));
export const inkNames = ["Graphite", "Blue", "Teal", "Red", "Violet"];
export const tints = {
  White: "#ffffff",
  Ivory: "#fdfaed",
  Cream: "#fff4d0",
  "Pale Blue": "#eaf5fb",
  Sage: "#ecf4e6",
  Blush: "#fceeeC",
};
export const rulings = ["Grid", "Ruled", "Dotted", "Whiteboard"];
export const uid = () => crypto.randomUUID().toUpperCase();
export const blank = () => ({
  version: 1,
  id: uid(),
  revision: 0,
  sourcePages: 0,
  objects: [],
});
export const defaultPaper = { ruling: "Grid", tint: "White" };
export const paper = (book, n) =>
  book.pagePaper?.[n] || book.defaultPaper || defaultPaper;
export const sourceIndex = (book, n) => {
  if (n < 0 || n >= book.sourcePages) return null;
  const i = book.sourcePageMap?.[n] ?? n;
  return i < 0 ? null : i;
};
export const pageCount = (book) =>
  book.objects.reduce(
    (n, o) => Math.max(n, Math.ceil((o.frame[0][1] + o.frame[1][1]) / H)),
    Math.max(
      1,
      book.sourcePages,
      book.minimumPages ?? 1,
      ...Object.keys(book.pagePaper || {}).map((n) => Number(n) + 1),
    ),
  );
export const kind = (o) => Object.keys(o.content)[0];
export const rgb = (c) =>
  "rgb(" + [c.r, c.g, c.b].map((v) => Math.round(v * 255)).join(",") + ")";
export const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
const dot = (a, b) => a[0] * b[0] + a[1] * b[1];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1]];
export const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
export const rect = ([a, b], [c, d]) => [
  [Math.min(a, c), Math.min(b, d)],
  [Math.abs(a - c), Math.abs(b - d)],
];
export const corners = ([[x, y], [w, h]]) => [
  [x, y],
  [x + w, y],
  [x + w, y + h],
  [x, y + h],
];
export const contains = ([[x, y], [w, h]], p, pad = 0) =>
  p[0] >= x - pad &&
  p[0] <= x + w + pad &&
  p[1] >= y - pad &&
  p[1] <= y + h + pad;
export const overlaps = (a, b) =>
  a[0][0] <= b[0][0] + b[1][0] &&
  b[0][0] <= a[0][0] + a[1][0] &&
  a[0][1] <= b[0][1] + b[1][1] &&
  b[0][1] <= a[0][1] + a[1][1];
export function bounds(points) {
  let l = Infinity,
    t = Infinity,
    r = -Infinity,
    b = -Infinity;
  for (const [x, y] of points) {
    l = Math.min(l, x);
    t = Math.min(t, y);
    r = Math.max(r, x);
    b = Math.max(b, y);
  }
  return [
    [l, t],
    [r - l, b - t],
  ];
}
export function groupRect(objects) {
  return objects.length
    ? bounds(objects.flatMap((o) => corners(o.frame)))
    : null;
}
export function near(p, a, b) {
  const u = sub(b, a),
    t = clamp(dot(sub(p, a), u) / Math.max(0.000001, dot(u, u)), 0, 1);
  return Math.hypot(p[0] - a[0] - t * u[0], p[1] - a[1] - t * u[1]);
}
function cross(a, b) {
  return a[0] * b[1] - a[1] * b[0];
}
function segments(a, b, c, d, r = 0) {
  const u = sub(b, a),
    v = sub(d, c),
    q = sub(c, a),
    den = cross(u, v);
  if (Math.abs(den) > 0.000001) {
    const t = cross(q, v) / den,
      s = cross(q, u) / den;
    if (t >= 0 && t <= 1 && s >= 0 && s <= 1) return true;
  }
  return (
    Math.min(near(a, c, d), near(b, c, d), near(c, a, b), near(d, a, b)) <= r
  );
}
export function makeInk(points, color, id = uid()) {
  const frame = bounds(
    points.flatMap(({ position: [x, y], radius: r }) => [
      [x - r, y - r],
      [x + r, y + r],
    ]),
  );
  return { id, frame, content: { ink: { _0: points, _1: color } } };
}
export function smooth(raw, amount, times = []) {
  if (
    raw.length < 3 ||
    amount <= 0 ||
    raw.reduce(
      (v, p, i) => (i ? v + dist(p.position, raw[i - 1].position) : 0),
      0,
    ) < 5
  )
    return raw;
  const pts = raw.map((p) => ({ ...p, position: [...p.position] }));
  const weights = raw.map(() => 0);
  for (let i = 1; i < raw.length - 1; i++) {
    const a = raw[i - 1].position,
      b = raw[i].position,
      c = raw[i + 1].position;
    const u = sub(b, a),
      v = sub(c, b),
      l = dist(a, b),
      m = dist(b, c);
    const dt = times.length === raw.length ? times[i + 1] - times[i - 1] : 0;
    const speedWeight = dt > 0 ? 1 / (1 + (l + m) / dt / 650) : 1;
    const k =
      speedWeight *
      clamp((dot(u, v) / Math.max(0.0001, l * m) - 0.7) / 0.26, 0, 1) *
      amount;
    weights[i] = k;
    const t = l / Math.max(0.001, l + m),
      dx = a[0] + (c[0] - a[0]) * t - b[0],
      dy = a[1] + (c[1] - a[1]) * t - b[1];
    const f = Math.min(0.46 * k, 0.85 / Math.max(0.001, Math.hypot(dx, dy)));
    pts[i].position = [b[0] + dx * f, b[1] + dy * f];
  }
  const out = [pts[0]];
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i].position,
      b = pts[i + 1].position,
      v = sub(b, a),
      len = dist(a, b);
    const u = sub(b, pts[Math.max(0, i - 1)].position),
      w = sub(pts[Math.min(pts.length - 1, i + 2)].position, a);
    const c1 = a.map(
      (x, j) =>
        x +
        (v[j] * (1 - weights[i]) +
          (u[j] * weights[i] * len) / Math.max(0.001, Math.hypot(...u))) /
          3,
    );
    const c2 = b.map(
      (x, j) =>
        x -
        (v[j] * (1 - weights[i + 1]) +
          (w[j] * weights[i + 1] * len) / Math.max(0.001, Math.hypot(...w))) /
          3,
    );
    const steps = clamp(Math.ceil(len / 1.8), 1, 1000);
    for (let j = 1; j <= steps; j++) {
      const t = j / steps,
        s = 1 - t;
      out.push({
        position: a.map(
          (x, k) =>
            s * s * s * x +
            3 * s * s * t * c1[k] +
            3 * s * t * t * c2[k] +
            t * t * t * b[k],
        ),
        radius: pts[i].radius + (pts[i + 1].radius - pts[i].radius) * t,
      });
    }
  }
  return out;
}
const fmt = (x) => String(Math.round(x * 1000) / 1000);
const pair = (p) => p.map(fmt).join(" ");
const outlines = new WeakMap();
export function inkPath(o) {
  if (outlines.has(o)) return outlines.get(o);
  const pts = o.content.ink._0;
  let path = "";
  const circle = ({ position: [x, y], radius: r }) =>
    "M" +
    pair([x + r, y]) +
    "a" +
    pair([r, r]) +
    " 0 1 0 " +
    pair([-2 * r, 0]) +
    "a" +
    pair([r, r]) +
    " 0 1 0 " +
    pair([2 * r, 0]) +
    "Z";
  const span = (a, b) => {
    const left = [],
      right = [];
    for (let i = a; i <= b; i++) {
      const p = pts[i],
        u = sub(p.position, pts[Math.max(a, i - 1)].position),
        v = sub(pts[Math.min(b, i + 1)].position, p.position);
      const lu = Math.max(0.000001, Math.hypot(...u)),
        lv = Math.max(0.000001, Math.hypot(...v));
      const sx = u[0] / lu + v[0] / lv,
        sy = u[1] / lu + v[1] / lv,
        ll = Math.max(0.000001, Math.hypot(sx, sy));
      const n = [-sy / ll, sx / ll],
        dir = i === b ? u : v,
        dl = i === b ? lu : lv;
      const r =
        p.radius / Math.max(0.72, (n[0] * -dir[1]) / dl + (n[1] * dir[0]) / dl);
      left.push([p.position[0] + n[0] * r, p.position[1] + n[1] * r]);
      right.push([p.position[0] - n[0] * r, p.position[1] - n[1] * r]);
    }
    const end = pts[b].radius,
      start = pts[a].radius;
    path +=
      "M" +
      left.map(pair).join("L") +
      "A" +
      pair([end, end]) +
      " 0 0 0 " +
      pair(right.at(-1));
    path +=
      "L" +
      right.reverse().slice(1).map(pair).join("L") +
      "A" +
      pair([start, start]) +
      " 0 0 0 " +
      pair(left[0]) +
      "Z";
  };
  if (pts.length === 1) path = circle(pts[0]);
  else {
    let start = 0;
    for (let i = 1; i < pts.length - 1; i++) {
      const a = sub(pts[i].position, pts[i - 1].position),
        b = sub(pts[i + 1].position, pts[i].position);
      if (dot(a, b) < -0.45 * Math.hypot(...a) * Math.hypot(...b)) {
        span(start, i);
        start = i;
      }
    }
    span(start, pts.length - 1);
  }
  outlines.set(o, path);
  return path;
}
export function touchesInk(o, a, b, r) {
  if (kind(o) !== "ink") return false;
  const region = rect(a, b);
  region[0][0] -= r;
  region[0][1] -= r;
  region[1][0] += 2 * r;
  region[1][1] += 2 * r;
  if (!overlaps(o.frame, region)) return false;
  const pts = o.content.ink._0;
  return pts.some((p, i) =>
    i
      ? segments(
          a,
          b,
          pts[i - 1].position,
          p.position,
          r + Math.max(p.radius, pts[i - 1].radius),
        )
      : near(p.position, a, b) <= r + p.radius,
  );
}
export function hit(o, p, r) {
  return kind(o) === "ink" ? touchesInk(o, p, p, r) : contains(o.frame, p, r);
}
function inside(p, poly) {
  let result = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i],
      b = poly[j];
    if (
      a[1] > p[1] !== b[1] > p[1] &&
      p[0] < ((b[0] - a[0]) * (p[1] - a[1])) / (b[1] - a[1]) + a[0]
    )
      result = !result;
  }
  return result;
}
export function regionHit(o, poly) {
  if (poly.length < 3 || !overlaps(o.frame, bounds(poly))) return false;
  const edges = poly.map((a, i) => [a, poly[(i + 1) % poly.length]]);
  if (kind(o) === "ink")
    return o.content.ink._0.some(
      (p, i, arr) =>
        inside(p.position, poly) ||
        edges.some(([a, b]) =>
          i
            ? segments(a, b, arr[i - 1].position, p.position, p.radius)
            : near(p.position, a, b) <= p.radius,
        ),
    );
  const box = corners(o.frame);
  return (
    box.some((p) => inside(p, poly)) ||
    poly.some((p) => contains(o.frame, p)) ||
    box.some((p, i) =>
      edges.some(([a, b]) => segments(p, box[(i + 1) % 4], a, b)),
    )
  );
}
export function transform(o, anchor, scale, dx, dy) {
  const apply = ([x, y]) => [
    anchor[0] + (x - anchor[0]) * scale + dx,
    anchor[1] + (y - anchor[1]) * scale + dy,
  ];
  if (kind(o) === "ink")
    return {
      ...o,
      ...makeInk(
        o.content.ink._0.map((p) => ({
          position: apply(p.position),
          radius: p.radius * scale,
        })),
        o.content.ink._1,
        o.id,
      ),
    };
  const copy = {
    ...o,
    frame: [apply(o.frame[0]), o.frame[1].map((n) => n * scale)],
  };
  if (kind(o) === "text")
    copy.content = {
      text: { ...o.content.text, _2: o.content.text._2 * scale },
    };
  if (o.layoutFrame)
    copy.layoutFrame = [
      apply(o.layoutFrame[0]),
      o.layoutFrame[1].map((n) => n * scale),
    ];
  return copy;
}
export function cleared(objects, page, deleting = false) {
  const top = page * H,
    bottom = top + H;
  return objects.flatMap((o) => {
    if (
      kind(o) === "image" ||
      o.frame[0][1] >= bottom ||
      o.frame[0][1] + o.frame[1][1] <= top
    )
      return [o];
    if (
      !deleting &&
      (o.instrument === "shape" || o.table || o.codeStyle != null)
    )
      return [o];
    if (kind(o) === "text") {
      const [[x, y], [w, h]] = o.frame,
        layoutFrame = o.layoutFrame || o.frame,
        out = [];
      if (y < top)
        out.push({
          ...o,
          layoutFrame,
          frame: [
            [x, y],
            [w, top - y],
          ],
        });
      if (y + h > bottom)
        out.push({
          ...o,
          id: out.length ? uid() : o.id,
          layoutFrame,
          frame: [
            [x, bottom],
            [w, y + h - bottom],
          ],
        });
      return out;
    }
    const data = o.content.ink,
      runs = [];
    let run = [];
    const add = (p) => {
      if (
        p.position[1] + p.radius >= top &&
        p.position[1] - p.radius < bottom
      ) {
        if (run.length) runs.push(run);
        run = [];
      } else run.push(p);
    };
    data._0.forEach((p, i) => {
      if (!i) {
        add(p);
        return;
      }
      const a = data._0[i - 1],
        steps = clamp(Math.ceil(dist(a.position, p.position) / 1.25), 1, 5000);
      for (let k = 1; k <= steps; k++) {
        let t = k / steps;
        add({
          position: a.position.map((v, j) => v + (p.position[j] - v) * t),
          radius: a.radius + (p.radius - a.radius) * t,
        });
      }
    });
    if (run.length) runs.push(run);
    return runs.map((r, i) => ({
      ...o,
      ...makeInk(r, data._1, i ? uid() : o.id),
    }));
  });
}
export function validate(book) {
  if (
    book?.version !== 1 ||
    typeof book.id !== "string" ||
    !Array.isArray(book.objects) ||
    !Number.isSafeInteger(book.sourcePages) ||
    book.sourcePages < 0 ||
    book.sourcePages > 100000 ||
    (book.minimumPages != null &&
      (!Number.isSafeInteger(book.minimumPages) ||
        book.minimumPages < 1 ||
        book.minimumPages > 100000))
  )
    throw Error("Unsupported or damaged notebook.");
  const checkFrame = (f) =>
    Array.isArray(f) &&
    f.length === 2 &&
    f.every(
      (p) => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite),
    ) &&
    f[1][0] > 0 &&
    f[1][1] > 0 &&
    f[0][1] + f[1][1] < 100000 * H;
  if (
    book.sourcePageMap != null &&
    (!Array.isArray(book.sourcePageMap) ||
      book.sourcePageMap.length !== book.sourcePages ||
      book.sourcePageMap.some(
        (n) => !Number.isInteger(n) || n < -1 || n >= 100000,
      ))
  )
    throw Error("Invalid source page mapping.");
  const ids = new Set();
  for (const o of book.objects) {
    if (!checkFrame(o.frame) || !o.id || ids.has(o.id))
      throw Error("Invalid notebook object.");
    ids.add(o.id);
    const k = kind(o),
      d = o.content[k];
    if (
      k === "ink" &&
      (!Array.isArray(d._0) ||
        !d._0.length ||
        d._0.some((p) => !(p.radius > 0) || !p.position.every(Number.isFinite)))
    )
      throw Error("Invalid ink data.");
    if (k === "text" && (typeof d._0 !== "string" || !Number.isFinite(d._2)))
      throw Error("Invalid text.");
    if (
      o.table &&
      (!Number.isInteger(o.table.rows) ||
        o.table.rows < 1 ||
        o.table.rows > 40 ||
        !Number.isInteger(o.table.columns) ||
        o.table.columns < 1 ||
        o.table.columns > 16 ||
        !Array.isArray(o.table.cells) ||
        o.table.cells.length !== o.table.rows * o.table.columns ||
        o.table.cells.some((s) => typeof s !== "string"))
    )
      throw Error("Invalid table.");
    if (k === "image" && typeof d._0 !== "string")
      throw Error("Missing image.");
    if (!["ink", "text", "image"].includes(k))
      throw Error("Unknown notebook object.");
  }
  return book;
}
function clipInk(o, top, bottom) {
  const points = o.content.ink._0,
    runs = [];
  let run = [];
  const flush = () => {
    if (run.length) runs.push(run);
    run = [];
  };
  if (points.length === 1) {
    const y = points[0].position[1];
    return y >= top && y < bottom ? [o] : [];
  }
  const interp = (a, b, t) => ({
    position: a.position.map((v, i) => v + t * (b.position[i] - v)),
    radius: a.radius + t * (b.radius - a.radius),
  });
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1],
      b = points[i],
      y = a.position[1],
      d = b.position[1] - y;
    let lo = 0,
      hi = 1;
    if (d === 0) {
      if (y < top || y >= bottom) {
        flush();
        continue;
      }
    } else {
      const l = (top - y) / d,
        h = (bottom - y) / d;
      lo = Math.max(0, Math.min(l, h));
      hi = Math.min(1, Math.max(l, h));
      if (hi <= lo) {
        flush();
        continue;
      }
    }
    if (!run.length) run.push(interp(a, b, lo));
    run.push(interp(a, b, hi));
    if (hi < 1) flush();
  }
  flush();
  return runs.map((pts, i) => ({
    ...o,
    ...makeInk(pts, o.content.ink._1, i ? uid() : o.id),
  }));
}
export function arrangedPages(book, order) {
  const destinations = new Map(
    order.flatMap((old, i) => (old == null ? [] : [[old, i]])),
  );
  const mapping = order.map((old) =>
    old == null ? -1 : (sourceIndex(book, old) ?? -1),
  );
  while (mapping.at(-1) === -1) mapping.pop();
  const styles = {};
  order.forEach((old, i) => {
    if (old != null && book.pagePaper?.[old]) styles[i] = book.pagePaper[old];
  });
  const objects = book.objects.flatMap((o) => {
    const [[x, y], [w, h]] = o.frame,
      first = Math.max(0, Math.floor(y / H)),
      last = Math.max(first, Math.ceil((y + h) / H) - 1),
      out = [];
    for (let index = first; index <= last; index++) {
      if (!destinations.has(index)) continue;
      const offset = destinations.get(index) - index,
        top = index * H;
      while (index < last && destinations.get(index + 1) === index + 1 + offset)
        index++;
      const bottom = (index + 1) * H;
      const pieces =
        y >= top && y + h <= bottom
          ? [o]
          : kind(o) === "ink"
            ? clipInk(o, top, bottom)
            : [
                {
                  ...o,
                  layoutFrame: o.layoutFrame || o.frame,
                  frame: [
                    [x, Math.max(y, top)],
                    [w, Math.min(y + h, bottom) - Math.max(y, top)],
                  ],
                },
              ];
      for (let piece of pieces) {
        if (out.length) piece = { ...piece, id: uid() };
        out.push(offset ? transform(piece, [0, 0], 1, 0, offset * H) : piece);
      }
    }
    return out;
  });
  return {
    ...book,
    objects,
    pagePaper: styles,
    sourcePages: mapping.length,
    sourcePageMap: mapping,
    minimumPages: Math.max(1, order.length),
  };
}

export function deletePage(book, n) {
  if (n < 0 || n >= pageCount(book)) return book;
  return arrangedPages(
    book,
    Array.from({ length: pageCount(book) }, (_, i) => i).filter((i) => i !== n),
  );
}
