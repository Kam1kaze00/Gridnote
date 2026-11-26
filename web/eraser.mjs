import { brushContactBetween, kind, makeInk, near, overlaps, rect } from "./engine.mjs";
const dot = (a, b) => a[0] * b[0] + a[1] * b[1];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1]];
function cutInterval(a, b, start, end, r) {
  const d = sub(b, a),
    cuts = [];
  function add(l, h) {
    l = Math.max(0, l);
    h = Math.min(1, h);
    if (h - l > 1e-6) cuts.push([l, h]);
  }
  function cap(c) {
    const o = sub(a, c),
      len = dot(d, d);
    if (len < 1e-12) {
      if (dot(o, o) < r * r) add(0, 1);
      return;
    }
    const t = -dot(o, d) / len,
      n = [o[0] + t * d[0], o[1] + t * d[1]],
      q = (r * r - dot(n, n)) / len;
    if (q > 0) {
      const w = Math.sqrt(q);
      add(t - w, t + w);
    }
  }
  cap(start);
  const travel = sub(end, start),
    length = Math.hypot(...travel);
  if (length > 1e-8) {
    cap(end);
    const axis = travel.map((v) => v / length),
      normal = [-axis[1], axis[0]],
      o = sub(a, start);
    let lo = 0,
      hi = 1;
    for (const [dir, l, h] of [
      [axis, 0, length],
      [normal, -r, r],
    ]) {
      const p = dot(o, dir),
        v = dot(d, dir);
      if (Math.abs(v) < 1e-10) {
        if (p < l || p > h) {
          hi = -1;
          break;
        }
      } else {
        const t = (l - p) / v,
          u = (h - p) / v;
        lo = Math.max(lo, Math.min(t, u));
        hi = Math.min(hi, Math.max(t, u));
      }
    }
    add(lo, hi);
  }
  return cuts.length
    ? [Math.min(...cuts.map((c) => c[0])), Math.max(...cuts.map((c) => c[1]))]
    : null;
}
function between(a, b, t) {
  return {
    position: a.position.map((v, i) => v + (b.position[i] - v) * t),
    ...brushContactBetween(a, b, t),
    radius: a.radius + (b.radius - a.radius) * t,
  };
}
// Return null for a miss so the caller can keep the original object and render cache.
export function erasePart(o, start, end, r) {
  if (kind(o) !== "ink") return null;
  const [[x, y], [w, h]] = rect(start, end);
  if (
    !overlaps(o.frame, [
      [x - r, y - r],
      [w + 2 * r, h + 2 * r],
    ])
  )
    return null;
  const { _0: pts, _1: color } = o.content.ink;
  if (pts.length === 1)
    return near(pts[0].position, start, end) <= r + pts[0].radius ? [] : null;
  let run = [pts[0]],
    changed = false;
  const pieces = [];
  function flush() {
    if (run.length) pieces.push({ ...o, ...makeInk(run, color) });
    run = [];
  }
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1],
      b = pts[i],
      cut = cutInterval(
        a.position,
        b.position,
        start,
        end,
        r + Math.max(a.radius, b.radius),
      );
    if (!cut) {
      if (!run.length) run.push(a);
      run.push(b);
      continue;
    }
    changed = true;
    if (cut[0] > 0) {
      if (!run.length) run.push(a);
      run.push(between(a, b, cut[0]));
      flush();
    } else if (run.length > 1) flush();
    else run = [];
    if (cut[1] < 1) run = [between(a, b, cut[1]), b];
  }
  if (!changed) return null;
  flush();
  return pieces;
}
