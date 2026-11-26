// The same paper-space masks are used in both editors. A missing resource can fall back to solid ink.
const pixels = 96, period = 13, area = pixels * pixels;
let atlas;
export const grainReady = fetch(new URL("./assets/writer-grain.bin", import.meta.url))
  .then(async response => response.ok ? new Uint8Array(await response.arrayBuffer()) : null)
  .then(data => { atlas = data; })
  .catch(() => {});
const patternCache = new Map();

export function grainIndex(nib) {
  if (!nib?.textured || atlas?.length !== 7 * area) return -1;
  if (nib.tip === "Brush") return nib.finish === "Dry" ? 2 : 1;
  return ({Pen:0, Fineliner:3, Gel:4, Fountain:5, Pencil:6})[nib.tip] ?? -1;
}

function colorBytes(ink) {
  return [ink.r, ink.g, ink.b].map(channel => Math.round(Math.max(0,Math.min(1,channel))*255));
}

export function grainPattern(ctx, index, ink) {
  const rgb = colorBytes(ink), key = [index,...rgb].join("/");
  if (patternCache.has(key)) return patternCache.get(key);
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = pixels;
  const tile = canvas.getContext("2d"), image = tile.createImageData(pixels,pixels);
  for (let i=0; i<area; i++) {
    image.data.set(rgb, i*4);
    image.data[i*4+3] = atlas[index*area+i];
  }
  tile.putImageData(image,0,0);
  const pattern = ctx.createPattern(canvas,"repeat");
  pattern.setTransform(new DOMMatrix().scale(period/pixels));
  if (patternCache.size >= 48) patternCache.clear();
  patternCache.set(key,pattern);
  return pattern;
}

function resource(lib, doc, page, type, name, ref) {
  const key = lib.PDFName.of(type), resources = page.node.Resources();
  let dict = resources.lookupMaybe(key,lib.PDFDict);
  if (!dict) { dict = doc.context.obj({}); resources.set(key,dict); }
  dict.set(name,ref);
}

// A PDF holds one small alpha image per material. The outline stays a vector path at any zoom.
export function printGrain(lib, doc, page, cache, index, ink, path, y, opacity) {
  const ctx = doc.context, name = lib.PDFName.of, rgb = colorBytes(ink);
  const imageKey = ["image",index,...rgb].join("/");
  let image = cache.get(imageKey);
  if (!image) {
    const attrs = {Type:"XObject",Subtype:"Image",Width:pixels,Height:pixels,
      BitsPerComponent:8,Interpolate:true};
    const maskKey = "mask/"+index;
    if (!cache.has(maskKey)) cache.set(maskKey,ctx.register(ctx.flateStream(
      atlas.subarray(index*area,(index+1)*area),{...attrs,ColorSpace:"DeviceGray"})));
    const bytes = new Uint8Array(area*3);
    for (let i=0; i<area; i++) bytes.set(rgb,i*3);
    image = ctx.register(ctx.flateStream(bytes,{...attrs,ColorSpace:"DeviceRGB",SMask:cache.get(maskKey)}));
    cache.set(imageKey,image);
  }
  const phase = y % period, key = imageKey+"/"+phase;
  let pattern = cache.get(key);
  if (!pattern) {
    const stream = ctx.flateStream("q "+period+" 0 0 "+(-period)+" 0 "+period+" cm /Ink Do Q",{
      Type:"Pattern",PatternType:1,PaintType:1,TilingType:1,BBox:[0,0,period,period],XStep:period,YStep:period,
      Matrix:[1,0,0,-1,0,phase],Resources:{XObject:{Ink:image}},
    });
    pattern = {name:name("WriterPaper"+cache.size),ref:ctx.register(stream)};
    cache.set(key,pattern);
  }
  resource(lib,doc,page,"Pattern",pattern.name,pattern.ref);
  const alphaKey = "opacity/"+opacity;
  let state = cache.get(alphaKey);
  if (!state) {
    state = {name:name("WriterAlpha"+cache.size),ref:ctx.register(ctx.obj({Type:"ExtGState",ca:opacity}))};
    cache.set(alphaKey,state);
  }
  resource(lib,doc,page,"ExtGState",state.name,state.ref);
  const ops = lib.drawSvgPath(path,{x:0,y,color:lib.rgb(ink.r,ink.g,ink.b),graphicsState:state.name});
  for (const op of ops) {
    if (op.name === "rg") page.pushOperators(lib.PDFOperator.of("cs",[name("Pattern")]),
      lib.PDFOperator.of("scn",[pattern.name]));
    else page.pushOperators(op);
  }
}
