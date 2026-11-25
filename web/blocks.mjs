import { clamp, dist, makeInk, rect } from "./engine.mjs";
export const markerNames = ["Yellow", "Mint", "Sky", "Coral", "Lilac"];
export const markers = [
  [1, 0.83, 0.08],
  [0.22, 0.84, 0.55],
  [0.18, 0.68, 1],
  [1, 0.46, 0.38],
  [0.66, 0.44, 1],
].map(([r, g, b]) => ({ r, g, b }));
export function tableGrid(rows, columns, header, old) {
  rows = clamp(Math.round(rows) || 3, 1, 40);
  columns = clamp(Math.round(columns) || 3, 1, 16);
  return {
    rows,
    columns,
    header,
    cells: Array.from({ length: rows * columns }, (_, i) => {
      const r = Math.floor(i / columns),
        c = i % columns;
      return old && r < old.rows && c < old.columns
        ? old.cells[r * old.columns + c]
        : "";
    }),
  };
}
export function cellFrame(o, i) {
  const [[x, y], [w, h]] = o.layoutFrame || o.frame,
    { rows, columns } = o.table;
  return [
    [
      x + ((i % columns) * w) / columns,
      y + (Math.floor(i / columns) * h) / rows,
    ],
    [w / columns, h / rows],
  ];
}
export function shapeObject(start, end, shape, lock, width, color) {
  let [dx, dy] = end.map((v, i) => v - start[i]);
  const len = Math.hypot(dx, dy);
  if (len < 1) return null;
  if (lock) {
    if (["Line", "Arrow"].includes(shape)) {
      const a =
        (Math.round((Math.atan2(dy, dx) * 12) / Math.PI) * Math.PI) / 12;
      dx = len * Math.cos(a);
      dy = len * Math.sin(a);
    } else {
      const side = Math.min(Math.abs(dx), Math.abs(dy));
      dx = Math.sign(dx) * side;
      dy = Math.sign(dy) * side;
    }
  }
  const [x, y] = start,
    a = x + dx,
    b = y + dy;
  let pts = [start, [a, b]];
  if (shape === "Box") pts = [start, [a, y], [a, b], [x, b], start];
  if (shape === "Arrow") {
    const n = Math.hypot(dx, dy),
      k = Math.min(n * 0.36, Math.max(8, width * 5)) / n;
    pts.push(
      [a - k * dx - 0.43 * k * dy, b - k * dy + 0.43 * k * dx],
      [a, b],
      [a - k * dx + 0.43 * k * dy, b - k * dy - 0.43 * k * dx],
    );
  }
  if (shape === "Oval") {
    const count = clamp(
      Math.ceil(Math.max(Math.abs(dx), Math.abs(dy)) * 0.45),
      24,
      360,
    );
    pts = Array.from({ length: count + 1 }, (_, i) => [
      x + (dx * (1 + Math.cos((i * 2 * Math.PI) / count))) / 2,
      y + (dy * (1 + Math.sin((i * 2 * Math.PI) / count))) / 2,
    ]);
  }
  return {
    ...makeInk(
      pts.map((position) => ({ position, radius: width / 2 })),
      color,
    ),
    instrument: "shape",
  };
}
export function align(box, targets, tolerance) {
  const adjust = [0, 0],
    guides = [];
  for (let axis = 0; axis < 2; axis++) {
    const marks = (f) => [0, 0.5, 1].map((k) => f[0][axis] + k * f[1][axis]);
    let best = tolerance + 0.00001,
      chosen;
    for (const t of targets)
      for (const m of marks(box))
        for (const v of marks(t)) {
          if (Math.abs(v - m) >= best) continue;
          best = Math.abs(v - m);
          adjust[axis] = v - m;
          const j = 1 - axis,
            lo = Math.min(box[0][j], t[0][j]),
            hi = Math.max(box[0][j] + box[1][j], t[0][j] + t[1][j]);
          chosen =
            axis === 0
              ? [
                  [v, lo],
                  [v, hi],
                ]
              : [
                  [lo, v],
                  [hi, v],
                ];
        }
    if (chosen) guides.push(chosen);
  }
  return { adjust, guides };
}
const lex =
  /(\/\/[^\n]*|\/\*[\s\S]*?(?:\*\/|$)|^\s*#(?!include|define|import)[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|(\b(?:if|else|for|while|return|break|continue|def|class|import|from|in|as|let|var|const|func|function|int|float|double|char|void|struct|bool|true|false|True|False|None|null|using|public|private|static|new|switch|case|end|include|define|printf|print|fn|mut|impl|trait|enum|match|package|interface|extends|async|await|yield|with|lambda|try|except|catch|throw|throws|finally|namespace|using|override|protected|final|val|fun|type|interface|SELECT|FROM|WHERE|JOIN|GROUP|ORDER|BY|INSERT|UPDATE|AND|OR|NULL|nil)\b)|(\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)/gm;
export function codeTokens(value, highlight) {
  if (!highlight) return [[value, "#20272b"]];
  let from = 0,
    tokens = [];
  for (const m of value.matchAll(lex)) {
    if (m.index > from) tokens.push([value.slice(from, m.index), "#20272b"]);
    tokens.push([
      m[0],
      ["#526b5f", "#9c3929", "#5945a5", "#155f8e"][
        m.slice(1).findIndex((v) => v !== undefined)
      ],
    ]);
    from = m.index + m[0].length;
  }
  tokens.push([value.slice(from), "#20272b"]);
  return tokens;
}
export function recognizeCode(text) {
  const f = text.match(/^\x60{3}[^\n]*\n([\s\S]*?)\n\x60{3}\s*$/);
  if (f) return [f[1], true];
  return [
    text,
    /^\s*(?:#include\s*[<"]|(?:int|void|double)\s+\w+\s*\(|(?:def|func|function|fn|fun|class|interface)\s+\w+\s*\(|(?:const|let|var|val)\s+\w+\s*=|return\s+[A-Za-z_0-9(][^\n;]*;?\s*$|(?:print|printf|console\.log|System\.out\.println)\s*\(|(?:SELECT|select)\s+.+\s+(?:FROM|from)\s+)/m.test(
      text,
    ),
  ];
}
export function paintBlock(ctx, o) {
  const [origin, [w, h]] = o.layoutFrame || o.frame,
    [x, y] = origin,
    size = o.content.text._2;
  ctx.save();
  ctx.beginPath();
  ctx.rect(...o.frame[0], ...o.frame[1]);
  ctx.clip();
  ctx.textBaseline = "top";
  if (o.table) {
    ctx.fillStyle = "#ffffffef";
    ctx.fillRect(x, y, w, h);
    o.table.cells.forEach((value, i) => {
      const [[cx, cy], [cw, ch]] = cellFrame(o, i),
        header = o.table.header && i < o.table.columns;
      if (header) {
        ctx.fillStyle = "#deede8";
        ctx.fillRect(cx, cy, cw, ch);
      }
      ctx.lineWidth = 0.55;
      ctx.strokeStyle = "#6b8287";
      ctx.strokeRect(cx, cy, cw, ch);
      const pt = Math.min(size, ch * 0.64);
      ctx.font = (header ? "600 " : "") + pt + "px Arial, sans-serif";
      ctx.fillStyle = "#20272b";
      ctx.save();
      ctx.beginPath();
      ctx.rect(cx + 2, cy + 1, Math.max(0, cw - 4), Math.max(0, ch - 2));
      ctx.clip();
      let line = 0,
        pos = 0;
      for (const ch of value) {
        const d = ctx.measureText(ch).width;
        if (ch === "\n" || (pos && pos + d > cw - 6)) {
          line++;
          pos = 0;
          if (ch === "\n") continue;
        }
        ctx.fillText(ch, cx + 3 + pos, cy + 2 + line * pt * 1.2);
        pos += d;
      }
      ctx.restore();
    });
  } else {
    ctx.fillStyle = "#f6f6f6";
    ctx.fillRect(x, y, w, h);
    ctx.font = size + "px ui-monospace, Menlo, Consolas, monospace";
    const cw = ctx.measureText("M").width;
    let col = 0,
      row = 0;
    for (const [token, color] of codeTokens(o.content.text._0, o.codeStyle)) {
      ctx.fillStyle = color;
      for (const ch of token) {
        if (ch === "\n") {
          row++;
          col = 0;
          continue;
        }
        if (col > 0 && (col + 1) * cw > w - 10) {
          col = 0;
          row++;
        }
        if (ch === "\t") col += 4 - (col % 4);
        else {
          ctx.fillText(ch, x + 5 + col * cw, y + 3 + row * size * 1.22);
          col++;
        }
      }
    }
  }
  ctx.restore();
}
