import { sourceIndex } from "./engine.mjs";
import {
  H,
  W,
  G,
  kind,
  inkPath,
  rgb,
  tints,
  paper,
  pageCount,
  overlaps,
} from "./engine.mjs";
import { paintBlock } from "./blocks.mjs";
let reader;
async function pdfjs() {
  if (!reader)
    reader = import("./vendor/pdf.mjs").then((module) => {
      module.GlobalWorkerOptions.workerSrc = new URL(
        "./vendor/pdf.worker.mjs",
        import.meta.url,
      ).href;
      return module;
    });
  return reader;
}
export function bytes64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 32768)
    binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
  return btoa(binary);
}
export function from64(data) {
  return Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
}
export async function readPDF(bytes) {
  const lib = await pdfjs(),
    asset = (folder) =>
      new URL("./vendor/" + folder + "/", import.meta.url).href;
  return lib.getDocument({
    data: bytes,
    cMapUrl: asset("cmaps"),
    cMapPacked: true,
    standardFontDataUrl: asset("standard_fonts"),
    wasmUrl: asset("wasm"),
    iccUrl: asset("iccs"),
    useSystemFonts: true,
    isEvalSupported: false,
  }).promise;
}
export async function pdfBitmap(doc, index, width, originalScale = false) {
  const page = await doc.getPage(index + 1),
    unit = page.getViewport({ scale: 1 });
  const s = (Math.min(W / unit.width, H / unit.height) * width) / W,
    view = page.getViewport({ scale: s });
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil(view.width);
  canvas.height = Math.ceil(view.height);
  if (originalScale) {
    const f = Math.min(1, W / unit.width, H / unit.height);
    canvas.paperSize = [unit.width * f, unit.height * f];
  }
  await page.render({
    canvasContext: canvas.getContext("2d"),
    viewport: view,
    canvas,
  }).promise;
  return canvas;
}
const paths = new WeakMap(),
  images = new Map();
export function imageOf(o, onReady) {
  const data = o.content.image._0;
  let existing = images.get(o.id);
  if (!existing || existing.data !== data) {
    const img = new Image();
    const promise = new Promise((resolve, reject) => {
      img.onload = () => {
        onReady?.();
        resolve(img);
      };
      img.onerror = () => reject(Error("Invalid embedded image."));
    });
    promise.catch(() => {});
    existing = { data, img, promise };
    images.set(o.id, existing);
    img.src = "data:image/png;base64," + data;
  }
  return existing;
}
export function resetImageCache() {
  images.clear();
}
const paperMascot = new Image();
paperMascot.addEventListener("load", () => window.dispatchEvent(new Event("gridnote-paper-loaded")));
paperMascot.src = new URL("./assets/pencil.png", import.meta.url).href;

function drawFolio(ctx, page) {
  ctx.fillStyle = "#6c6757";
  ctx.font = "italic bold 12px Georgia, serif";
  ctx.fillText(String(page + 1).padStart(2, "0"), 12, 24);
  ctx.fillRect(12, 28, 17, 0.65);
  if (paperMascot.complete && paperMascot.naturalWidth) {
    ctx.globalAlpha = 0.72;
    ctx.drawImage(paperMascot, W - 43, 4, 34, 32);
  }
}
function paperColor(design) {
  return design.cartoon && design.tint === "Ivory" ? "#f8f4e8" : tints[design.tint] || "#ffffff";
}
export function paintPaper(ctx, page, design) {
  const y = page * H;
  ctx.fillStyle = paperColor(design);
  ctx.fillRect(0, y, W, H);
  if (design.ruling === "Whiteboard") return;
  ctx.save();
  ctx.beginPath();
  ctx.rect(0, y, W, H);
  ctx.clip();
  if (design.ruling === "Dotted") {
    ctx.fillStyle = "rgba(112,138,153,.52)";
    ctx.beginPath();
    for (let x = 0; x <= W; x += G)
      for (let j = 0; j <= H; j += G) {
        ctx.moveTo(x + 0.6, y + j);
        ctx.arc(x, y + j, 0.6, 0, 2 * Math.PI);
      }
    ctx.fill();
  } else {
    ctx.lineWidth = 0.35;
    ctx.strokeStyle = design.cartoon ? "rgba(115,107,85,.25)" : "rgba(120,158,181,.37)";
    ctx.beginPath();
    if (design.ruling === "Grid")
      for (let x = 0; x <= W; x += G) {
        ctx.moveTo(x, y);
        ctx.lineTo(x, y + H);
      }
    const spacing = design.ruling === "Ruled" ? (7 * 72) / 25.4 : G;
    for (let j = 0; j <= H; j += spacing) {
      ctx.moveTo(0, y + j);
      ctx.lineTo(W, y + j);
    }
    ctx.stroke();
    ctx.strokeStyle = design.cartoon ? "#ae7770" : "rgba(196,94,107,.72)";
    ctx.lineWidth = 0.65;
    ctx.beginPath();
    ctx.moveTo(4 * G, y);
    ctx.lineTo(4 * G, y + H);
    if (design.cartoon) { ctx.moveTo(4 * G - 2.2, y); ctx.lineTo(4 * G - 2.2, y + H); }
    ctx.stroke();
  }
  if (design.cartoon) {
    ctx.translate(0, y);
    drawFolio(ctx, page);
  }
  ctx.restore();
}
export function textLines(ctx, value, width) {
  const lines = [];
  for (const paragraph of value.split("\n")) {
    let line = "";
    for (const word of paragraph.match(/\S+\s*|\s+/gu) || []) {
      if (line && ctx.measureText(line + word).width > width) {
        lines.push(line.trimEnd());
        line = "";
      }
      if (ctx.measureText(word).width > width) {
        for (const ch of word) {
          if (line && ctx.measureText(line + ch).width > width) {
            lines.push(line);
            line = "";
          }
          line += ch;
        }
      } else line += word;
    }
    lines.push(line.trimEnd());
  }
  return lines;
}
export function paintObject(ctx, o, onReady) {
  const [[x, y], [w, h]] = o.frame;
  if (o.table || o.codeStyle != null) {
    paintBlock(ctx, o);
    return;
  }
  if (kind(o) === "ink") {
    let p = paths.get(o);
    if (!p) {
      p = new Path2D(inkPath(o));
      paths.set(o, p);
    }
    ctx.save();
    if (o.instrument === "marker") {
      ctx.globalCompositeOperation = "multiply";
      ctx.globalAlpha = o.opacity ?? 0.38;
    }
    ctx.fillStyle = rgb(o.content.ink._1);
    ctx.fill(p);
    ctx.restore();
    return;
  }
  if (kind(o) === "image") {
    const { img } = imageOf(o, onReady);
    if (img.naturalWidth) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(x, y, w, h);
      ctx.clip();
      const [origin, size] = o.layoutFrame || o.frame;
      ctx.drawImage(img, ...origin, ...size);
      ctx.restore();
    }
    return;
  }
  const { _0: value, _1: color, _2: size } = o.content.text;
  const [[lx, ly], [lw]] = o.layoutFrame || o.frame;
  ctx.save();
  ctx.beginPath();
  ctx.rect(x, y, w, h);
  ctx.clip();
  ctx.fillStyle = rgb(color);
  ctx.font = size + "px -apple-system, BlinkMacSystemFont, Arial, sans-serif";
  ctx.textBaseline = "top";
  const lines = textLines(ctx, value, lw);
  lines.forEach((line, i) => {
    const rtl = /^[^a-zA-Z\u0590-\u08ff]*[\u0590-\u08ff]/.test(line);
    const alignment =
      o.alignment === "Right"
        ? "right"
        : o.alignment === "Center"
          ? "center"
          : o.alignment === "Auto" && rtl
            ? "right"
            : "left";
    ctx.direction = rtl ? "rtl" : "ltr";
    ctx.textAlign = alignment;
    ctx.fillText(
      line,
      lx + (alignment === "right" ? lw : alignment === "center" ? lw / 2 : 0),
      ly + size * 0.12 + i * size * 1.2,
    );
  });
  ctx.restore();
}
export function drawPDFImage(ctx, img, index) {
  const f = Math.min(W / img.width, H / img.height),
    w = img.paperSize?.[0] ?? img.width * f,
    h = img.paperSize?.[1] ?? img.height * f;
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, index * H, W, H);
  ctx.drawImage(img, (W - w) / 2, index * H + (H - h) / 2, w, h);
}
export async function makePDF(book, source, progress) {
  const lib = await import("./vendor/pdf-lib.mjs"),
    doc = await lib.PDFDocument.create();
  doc.setCreator("Gridnote");
  doc.setProducer("Gridnote");
  const pngs = new Map();
  const total = pageCount(book);
  for (let i = 0; i < total; i++) {
    progress?.(i + 1, total);
    const page = doc.addPage([W, H]),
      top = i * H;
    const raster = async (draw, w, h, f = 2.5) => {
      const surface = document.createElement("canvas");
      surface.width = Math.max(1, Math.ceil(w * f));
      surface.height = Math.max(1, Math.ceil(h * f));
      const ctx = surface.getContext("2d");
      ctx.scale(surface.width / w, surface.height / h);
      await draw(ctx);
      const blob = await new Promise((resolve, reject) =>
        surface.toBlob(
          (b) => (b ? resolve(b) : reject(Error("Image rendering failed."))),
          "image/png",
        ),
      );
      const result = await doc.embedPng(await blob.arrayBuffer());
      surface.width = surface.height = 1;
      return result;
    };
    if (sourceIndex(book, i) != null) {
      const image = await pdfBitmap(
        source,
        book.sourcePageMap?.[i] ?? i,
        Math.ceil(W * 3),
        book.originalPDFScale,
      );
      const base = await raster((ctx) => drawPDFImage(ctx, image, 0), W, H, 3);
      page.drawImage(base, { x: 0, y: 0, width: W, height: H });
      image.width = image.height = 1;
    } else {
      const design = paper(book, i),
        hex = paperColor(design);
      const [r, g, b] = [1, 3, 5].map(
        (k) => parseInt(hex.slice(k, k + 2), 16) / 255,
      );
      page.drawRectangle({
        x: 0,
        y: 0,
        width: W,
        height: H,
        color: lib.rgb(r, g, b),
      });
      const line = (x, y, a, b, color, thickness, opacity) =>
        page.drawLine({
          start: { x, y },
          end: { x: a, y: b },
          color,
          thickness,
          opacity,
        });
      const grid = design.cartoon ? lib.rgb(115/255,107/255,85/255) : lib.rgb(0.47, 0.62, 0.71);
      const gridOpacity = design.cartoon ? 0.25 : 0.37;
      if (design.ruling === "Grid")
        for (let x = 0; x <= W; x += G) line(x, 0, x, H, grid, 0.35, gridOpacity);
      if (design.ruling === "Grid" || design.ruling === "Ruled") {
        const spacing = design.ruling === "Grid" ? G : (7 * 72) / 25.4;
        for (let y = 0; y <= H; y += spacing)
          line(0, H - y, W, H - y, grid, 0.35, gridOpacity);
        const margin = design.cartoon ? lib.rgb(174/255,119/255,112/255) : lib.rgb(0.77,0.37,0.42);
        line(4 * G, 0, 4 * G, H, margin, 0.65, design.cartoon ? 1 : 0.72);
        if (design.cartoon) line(4 * G - 2.2, 0, 4 * G - 2.2, H, margin, 0.65, 1);
      } else if (design.ruling === "Dotted") {
        // Tile one vector dot using a single graphics-state setup.
        page.pushOperators(
          lib.pushGraphicsState(),
          lib.setFillingRgbColor(0.67, 0.72, 0.75),
        );
        const k = 0.33137,
          r = 0.6;
        for (let x = 0; x <= W; x += G)
          for (let y = H; y >= 0; y -= G) {
            page.pushOperators(
              lib.moveTo(x + r, y),
              lib.appendBezierCurve(x + r, y + k, x + k, y + r, x, y + r),
              lib.appendBezierCurve(x - k, y + r, x - r, y + k, x - r, y),
              lib.appendBezierCurve(x - r, y - k, x - k, y - r, x, y - r),
              lib.appendBezierCurve(x + k, y - r, x + r, y - k, x + r, y),
              lib.closePath(),
            );
          }
        page.pushOperators(lib.fill(), lib.popGraphicsState());
      }
      if (design.cartoon && design.ruling !== "Whiteboard") {
        await paperMascot.decode();
        const folio = await raster(ctx => drawFolio(ctx, i), W, 38);
        page.drawImage(folio, { x: 0, y: H - 38, width: W, height: 38 });
      }
    }
    for (const o of book.objects) {
      if (
        !overlaps(o.frame, [
          [0, top],
          [W, H],
        ])
      )
        continue;
      const [[x, y], [w, h]] = o.frame;
      if (kind(o) === "ink") {
        const c = o.content.ink._1;
        page.drawSvgPath(inkPath(o), {
          x: 0,
          y: H + top,
          color: lib.rgb(c.r, c.g, c.b),
          opacity: o.opacity ?? 1,
          blendMode:
            o.instrument === "marker" ? lib.BlendMode.Multiply : undefined,
        });
      } else if (kind(o) === "image") {
        let img = pngs.get(o.id);
        if (!img) {
          img = await doc.embedPng(from64(o.content.image._0));
          pngs.set(o.id, img);
        }
        const [[lx, ly], [lw, lh]] = o.layoutFrame || o.frame;
        page.pushOperators(
          lib.pushGraphicsState(),
          lib.rectangle(x, H + top - y - h, w, h),
          lib.clip(),
          lib.endPath(),
        );
        page.drawImage(img, {
          x: lx,
          y: H + top - ly - lh,
          width: lw,
          height: lh,
        });
        page.pushOperators(lib.popGraphicsState());
      } else {
        const img = await raster(
          (ctx) => {
            ctx.translate(-x, -y);
            paintObject(ctx, o);
          },
          w,
          h,
          Math.min(3, 4096 / Math.max(w, h)),
        );
        page.drawImage(img, { x, y: H + top - y - h, width: w, height: h });
      }
    }
  }
  return doc.save();
}
