// Graphite fills the tooth of the paper. A reusable tile keeps its cost independent of stroke length.
const spacing = 0.43, side = 24 * spacing;
const inkTiles = new Map();
const patches = [];
function noise(index) {
  let v = index + 1;
  v = Math.imul(v ^ (v >>> 16), 0x45d9f3b);
  v = Math.imul(v ^ (v >>> 16), 0x45d9f3b);
  return (v ^ (v >>> 16)) >>> 0;
}
for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) {
  const n = noise(x + y*24), patch = noise((x >> 1) + (y >> 1)*12 + 763);
  if (n % 256 < (patch % 2 === 0 ? 105 : 184))
    patches.push([x*spacing, y*spacing, (0.60 + ((n>>>8)%76)/100)*spacing, (0.55 + ((n>>>16)%71)/100)*spacing]);
}

export function inkLayers(tip, finish) {
  if (tip === "Brush" && finish === "Inked") return [0.59, 0.96];
  if (tip === "Brush" && finish === "Dry") return [0.055, 0.94];
  switch (tip) {
    case "Pencil": return [0.20, 0.66];
    case "Fountain": return [0.56, 0.81];
    case "Brush": return [0.21, 1];
    default: return [0.43, 1];
  }
}
export function graphitePattern(ctx, color) {
  let tile = inkTiles.get(color);
  if (!tile) {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 96;
    const grain = canvas.getContext("2d");
    grain.scale(96/side, 96/side);
    grain.fillStyle = color;
    grain.beginPath();
    for (const rect of patches) grain.rect(...rect);
    grain.fill();
    tile = ctx.createPattern(canvas, "repeat");
    tile.setTransform(new DOMMatrix().scale(side/96));
    if (inkTiles.size > 24) inkTiles.clear();
    inkTiles.set(color, tile);
  }
  return tile;
}

// Each PDF page references the same small vector tile for all strokes of one color.
export function graphitePDFFill(lib, doc, page, cache, ink, path, y) {
  const name = lib.PDFName.of, key = [ink.r, ink.g, ink.b].join(" ");
  let record = cache.get(key);
  if (!record) {
    const geometry = patches.map(rect => rect.map(x => x.toFixed(4)).join(" ") + " re").join("\n");
    const stream = doc.context.flateStream(key + " rg\n/G gs\n" + geometry + "\nf", {
      Type: "Pattern", PatternType: 1, PaintType: 1, TilingType: 1, BBox: [0,0,side,side],
      XStep: side, YStep: side, Resources: {ExtGState:{G:{Type:"ExtGState",ca:inkLayers("Pencil")[1]}}},
    });
    record = {ref:doc.context.register(stream), name:name("GridnoteGrain"+cache.size)};
    cache.set(key,record);
  }
  const resources = page.node.Resources();
  let patterns = resources.lookupMaybe(name("Pattern"), lib.PDFDict);
  if (!patterns) { patterns = doc.context.obj({}); resources.set(name("Pattern"), patterns); }
  patterns.set(record.name, record.ref);
  // drawSvgPath supplies the same co-ordinate conversion and outline operators as the other tips.
  const ops = lib.drawSvgPath(path,{x:0,y,color:lib.rgb(ink.r,ink.g,ink.b)});
  for (const op of ops) {
    if (op.name === "rg") page.pushOperators(
      lib.PDFOperator.of("cs",[name("Pattern")]), lib.PDFOperator.of("scn",[record.name]));
    else page.pushOperators(op);
  }
}
