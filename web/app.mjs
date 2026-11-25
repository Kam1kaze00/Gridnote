import { pageSidebar } from "./pages.mjs";
import { arrangedPages, sourceIndex } from "./engine.mjs";
import { erasePart } from "./eraser.mjs";
import { scanProblems, studyContent } from "./study.mjs";
import {
  markers,
  markerNames,
  tableGrid,
  cellFrame,
  shapeObject,
  align,
  recognizeCode,
} from "./blocks.mjs";
import { cameraSupported, capturePhoto } from "./camera.mjs";
import {
  W,
  H,
  G,
  uid,
  blank,
  defaultPaper,
  paper,
  pageCount,
  kind,
  inks,
  inkNames,
  tints,
  rulings,
  rgb,
  dist,
  clamp,
  rect,
  corners,
  bounds,
  groupRect,
  contains,
  overlaps,
  makeInk,
  inkPath,
  smooth,
  touchesInk,
  hit,
  regionHit,
  transform,
  cleared,
  validate,
  deletePage,
} from "./engine.mjs";
import {
  loadState,
  saveState,
  saveRecord,
  loadRecord,
  library,
} from "./store.mjs";
import {
  devices,
  device,
  observePointer,
  detectHardware,
  deviceLabel,
  mobileSurface,
  fingerWrites,
  useFinger,
  pressureResponse,
  restore,
  majors,
  major,
  chooseMajor,
  settings,
  setting,
  deviceHelp,
} from "./devices.mjs";
import {
  paintPaper,
  paintObject,
  drawPDFImage,
  readPDF,
  pdfBitmap,
  makePDF,
  from64,
  bytes64,
  resetImageCache,
} from "./render.mjs";

const $ = (id) => document.getElementById(id);
const view = $("view"),
  world = $("world"),
  sheet = $("sheet"),
  editor = $("editor"),
  pop = $("popover"),
  ctx = sheet.getContext("2d");
const toolNames = {
  brush: ["Brush", "Q", "✎"],
  selector: ["Selector", "W", "⌖"],
  eraser: ["Eraser", "E", "◇"],
  text: ["Text", "R", "T"],
  marker: ["Highlighter", "", "▰"],
  shapes: ["Shapes", "", "△"],
  table: ["Table", "", "▦"],
};
let book,
  title = "",
  source = null,
  tool = "brush",
  zoom = 1,
  scale = 1,
  pages = 2,
  selection = new Set(),
  gesture = null,
  armed = false,
  space = false,
  lower = false,
  upper = false;
let editing = null,
  undo = [],
  redo = [],
  lastRevision = 0,
  dirty = false,
  saveTimer,
  stateTimer,
  saveQueue = Promise.resolve(),
  error = "",
  restoring = false,
  paintFrame = 0;
let pdfCache = new Map(),
  pdfResult = null,
  pdfPreview = null,
  pdfIndex = 0,
  previewEpoch = 0,
  popupKind = "",
  paperScope = "page",
  noticeTimer;
let touches = new Map(),
  touchGesture = null,
  penContact = null,
  panRemainder = 0,
  panFrame = 0,
  ignoreContact = false,
  stylusCursor = null,
  liveInk = null;
let studyItems = [],
  studySequence = 0;
const historyLimit = 70;
const point = (e) => {
  const r = sheet.getBoundingClientRect();
  return [
    (view.scrollLeft + e.clientX - r.left) / scale,
    (view.scrollTop + e.clientY - r.top) / scale,
  ];
};
const currentPage = () =>
  Math.max(
    0,
    Math.floor(
      (view.scrollTop / scale +
        Math.min((view.clientHeight / scale) * 0.24, 85)) /
        H,
    ),
  );
const color = () => inks[settings().ink];
const selected = () => book.objects.filter((o) => selection.has(o.id));
const inFilter = (o) =>
  (settings().mask & { ink: 1, text: 2, image: 4 }[kind(o)]) !== 0;
const effective = () => (armed ? "eraser" : tool);
const $el = (tag, text) => {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  return e;
};
function button(label, action, cls = "") {
  const b = $el("button", label);
  b.type = "button";
  b.className = cls;
  b.onclick = action;
  return b;
}
function notify(text) {
  $("notice").textContent = text;
  $("notice").hidden = false;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => ($("notice").hidden = true), 4300);
}
const run = async (fn) => {
  try {
    return await fn();
  } catch (e) {
    notify(e?.message || String(e));
  }
};
function download(blob, name) {
  const url = URL.createObjectURL(blob),
    a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 120000);
}
function updateStatus() {
  const b = $("saved");
  b.textContent = error ? "Save error" : dirty ? "Saving…" : "Saved";
  b.classList.toggle("error", !!error);
  b.title = error || "Saved on this device. Click to save now.";
}
function snapshot() {
  let s = book;
  if (editing?.parent) {
    const cells = [...editing.parent.table.cells];
    cells[editing.cell] = editor.value;
    return {
      ...book,
      objects: book.objects.map((o) =>
        o.id === editing.parent.id ? { ...o, table: { ...o.table, cells } } : o,
      ),
    };
  }
  if (editing) {
    const value = editor.stringValue ?? editor.value;
    const o = textObject(
      editing.object,
      value,
      editing.object.frame[0],
      editing.object.content.text._2,
      editing.object.content.text._1,
    );
    const list = book.objects.filter((x) => x.id !== o.id);
    if (value.trim()) {
      const idx = book.objects.findIndex((x) => x.id === o.id);
      list.splice(idx < 0 ? list.length : idx, 0, o);
    }
    s = { ...s, objects: list };
  }
  if (gesture?.type === "ink" && gesture.raw.length) {
    const draft = currentInk();
    s = { ...s, objects: [...s.objects, draft] };
  }
  return s;
}
function touchSave() {
  studyItems = [];
  studySequence++;
  $("solve").textContent = "Solve";
  $("solve").disabled = false;
  book = { ...book, revision: book.revision + 1 };
  dirty = true;
  updateStatus();
  if (!saveTimer)
    saveTimer = setTimeout(() => {
      saveTimer = 0;
      flush().catch(() => {});
    }, 140);
}
function flush() {
  clearTimeout(saveTimer);
  saveTimer = 0;
  const task = async () => {
    if (!book || !dirty) return;
    const snap = snapshot(),
      name = title;
    try {
      const revision = await saveRecord(snap, name, lastRevision);
      if (snap.id === book.id) {
        lastRevision = revision;
        dirty = book.revision !== revision;
        error = "";
        updateStatus();
      }
    } catch (e) {
      error = e.message || "Local save failed.";
      dirty = true;
      updateStatus();
      throw e;
    }
  };
  saveQueue = saveQueue.catch(() => {}).then(task);
  return saveQueue;
}
function positionState() {
  return {
    zoom,
    x: view.scrollLeft / scale,
    y: view.scrollTop / scale,
    tool,
    selection: [...selection],
    editing: editing?.object.id,
    cell: editing?.cell,
    caret: editor.selectionStart,
    length: editor.selectionEnd - editor.selectionStart,
  };
}
function recordView(now = false) {
  if (!book || restoring) return;
  clearTimeout(stateTimer);
  const store = () => {
    const id = book.id,
      state = positionState();
    try {
      localStorage.setItem("gridnote-view-" + id, JSON.stringify(state));
    } catch {}
    saveState("view-" + id, state).catch((e) => {
      error = e.message;
      updateStatus();
    });
  };
  if (now) store();
  else stateTimer = setTimeout(store, 100);
}
function endTransient() {
  erasingContact = false;
  lower = false;
  upper = false;
  armed = false;
  space = false;
  ignoreContact = false;
  penContact = null;
  touches.clear();
  touchGesture = null;
  if (panFrame) cancelAnimationFrame(panFrame);
  panFrame = 0;
  panRemainder = 0;
}
function setObjects(next, name, previous = book.objects) {
  if (next === previous) return;
  undo.push({ objects: previous, label: name });
  if (undo.length > historyLimit) undo.shift();
  redo = [];
  book = { ...book, objects: next };
  touchSave();
  resize();
  refresh();
}
function changePaper(design) {
  const previous = {
    defaultPaper: book.defaultPaper,
    pagePaper: book.pagePaper,
  };
  undo.push({ paper: previous, label: "Change paper" });
  redo = [];
  if (paperScope === "default") {
    book = { ...book, defaultPaper: design };
  } else {
    const overrides = { ...book.pagePaper };
    overrides[currentPage()] = design;
    book = { ...book, pagePaper: overrides };
  }
  touchSave();
  refresh();
  draw();
}
function stepHistory(from, to) {
  finishText();
  finishGesture();
  const entry = from.pop();
  if (!entry) return;
  if (entry.document) {
    to.push({ document: book, label: entry.label });
    book = { ...entry.document, revision: book.revision };
    pdfCache.clear();
  } else if (entry.paper) {
    to.push({
      paper: { defaultPaper: book.defaultPaper, pagePaper: book.pagePaper },
      label: entry.label,
    });
    book = { ...book, ...entry.paper };
  } else {
    to.push({ objects: book.objects, label: entry.label });
    book = { ...book, objects: entry.objects };
  }
  selection.clear();
  touchSave();
  resize();
  refresh();
}
async function openBook(next, name, state = null, stored = null) {
  if (book) {
    finishText();
    finishGesture();
    recordView(true);
    await flush();
  }
  restoring = true;
  // Load the incoming PDF before replacing the currently open notebook.
  let nextPDF;
  try {
    nextPDF = next.sourcePDF ? await readPDF(from64(next.sourcePDF)) : null;
  } catch (e) {
    restoring = false;
    throw e;
  }
  if (source) await source.destroy();
  studyItems = [];
  studySequence++;
  source = nextPDF;
  pdfCache.clear();
  resetImageCache();
  book = next;
  title = name;
  lastRevision = stored ?? next.revision;
  dirty = false;
  error = "";
  undo = [];
  redo = [];
  endTransient();
  selection = new Set(state?.selection || []);
  tool = toolNames[state?.tool] ? state.tool : "brush";
  zoom = clamp(Number(state?.zoom) || 1, 1, 4);
  pages = Math.max(2, pageCount(book) + 1, Math.ceil((state?.y || 0) / H) + 2);
  $("welcome").hidden = true;
  for (const id of [
    "tools",
    "stage",
    "bottom",
    "saved",
    "solve",
    "preview",
    "export",
  ])
    $(id).hidden = false;
  $("name").textContent = title;
  document.title = title + " · Gridnote";
  resize();
  view.scrollTo((state?.x || 0) * scale, (state?.y || 0) * scale);
  if (state?.editing) {
    const o = book.objects.find(
      (x) => x.id === state.editing && kind(x) === "text",
    );
    if (o) {
      if (o.table) startCell(o, state.cell ?? 0, state.caret, state.length);
      else startText(o.frame[0], o, state.caret, state.length);
    }
  }
  restoring = false;
  refresh();
  draw();
  recordView(true);
  await saveState("last", book.id);
}
async function openStored(id) {
  const loaded = await loadRecord(id);
  if (!loaded) throw Error("The notebook is unavailable.");
  let state;
  try {
    state = JSON.parse(localStorage.getItem("gridnote-view-" + id));
  } catch {}
  state ??= await loadState("view-" + id);
  await openBook(loaded.book, loaded.title, state, loaded.storedRevision);
  if (loaded.recovered) {
    touchSave();
    notify("Restored a recent recovery copy.");
  }
}
async function newBook() {
  await openBook(blank(), "Untitled Notebook");
  touchSave();
  await flush();
}
const pagesPanel = $("pages-panel");
function jumpPage(p) {
  resize();
  view.scrollTo(view.scrollLeft, p * H * scale);
  refresh();
  recordView();
}
function organizePage(action, p, to) {
  finishText();
  finishGesture();
  const order = Array.from({ length: pageCount(book) }, (_, i) => i);
  let target = p;
  if (!Number.isInteger(p) || p < 0 || p >= order.length) return;
  if (action === "insert") {
    if (order.length >= 99999) return;
    order.splice(++target, 0, null);
  } else if (action === "delete") {
    order.splice(p, 1);
    target = Math.max(0, Math.min(p, order.length - 1));
  } else {
    target = action === "move" ? to : p + (action === "up" ? -1 : 1);
    if (target < 0 || target >= order.length || target === p) return;
    order.splice(target, 0, order.splice(p, 1)[0]);
  }
  undo.push({
    document: book,
    label:
      action === "delete"
        ? "Delete page"
        : action === "insert"
          ? "Insert page"
          : "Move page",
  });
  redo = [];
  book = arrangedPages(book, order);
  selection.clear();
  pdfCache.clear();
  touchSave();
  jumpPage(target);
}
const updateSidebar = pageSidebar(pagesPanel, {
  jump: jumpPage,
  change: organizePage,
});
$("page").onclick = () => {
  pagesPanel.hidden = !pagesPanel.hidden;
  $("page").setAttribute("aria-expanded", String(!pagesPanel.hidden));
  resize();
  refresh();
};
function refresh() {
  if (!book) return;
  updateSidebar(book, source, currentPage());
  $("subjects").hidden = major() === "None";
  const prefs = settings();
  for (const id of Object.keys(toolNames))
    $("tool-" + id).setAttribute("aria-pressed", String(id === effective()));
  sheet.className = lower || gesture?.type === "pan" ? "pan" : effective();
  $("undo").disabled = !undo.length && !editing;
  $("redo").disabled = !redo.length && !editing;
  $("page").textContent = "Page " + (currentPage() + 1);
  $("paper").textContent =
    "A4 · " +
    (sourceIndex(book, currentPage()) != null
      ? "PDF"
      : paper(book, currentPage()).ruling) +
    " ⌄";
  $("selection").hidden = tool !== "selector" || !selection.size;
  $("selection").textContent = selection.size + " selected ⌄";
  $("zoom").textContent = Math.round(zoom * 100) + "%";
  $("zoomout").disabled = zoom <= 1.001;
  $("zoomin").disabled = zoom >= 3.999;
  $("inks").hidden = !prefs.palette;
  $("palette").setAttribute("aria-pressed", String(prefs.palette));
  for (const [i, b] of [...$("inks").children].entries()) {
    const marker = tool === "marker";
    b.style.setProperty("--swatch", rgb((marker ? markers : inks)[i]));
    b.title = (marker ? markerNames : inkNames)[i];
    b.setAttribute("aria-label", b.title);
    b.setAttribute(
      "aria-pressed",
      String(
        i ===
          (marker
            ? prefs.markerInk
            : tool === "text"
              ? prefs.textInk
              : prefs.ink),
      ),
    );
  }
  updateStatus();
  draw();
}
function resize() {
  if (!book) return;
  const oldScale = scale,
    oldX = view.scrollLeft / oldScale,
    oldY = view.scrollTop / oldScale;
  scale = Math.max(0.01, (view.clientWidth / W) * zoom);
  pages = Math.max(
    pages,
    pageCount(book) + 1,
    Math.ceil((oldY + view.clientHeight / scale) / H) + 1,
  );
  world.style.width = W * scale + "px";
  world.style.height = pages * H * scale + "px";
  const w = Math.max(1, view.clientWidth),
    h = Math.max(1, view.clientHeight),
    dpr = Math.min(devicePixelRatio || 1, 2.5);
  sheet.style.width = w + "px";
  sheet.style.height = h + "px";
  if (
    sheet.width !== Math.round(w * dpr) ||
    sheet.height !== Math.round(h * dpr)
  ) {
    sheet.width = Math.round(w * dpr);
    sheet.height = Math.round(h * dpr);
  }
  if (Math.abs(oldScale - scale) > 0.001)
    view.scrollTo(oldX * scale, oldY * scale);
  if (editing) placeEditor();
  draw();
}
function setZoom(n, screen = [view.clientWidth / 2, view.clientHeight / 2]) {
  const doc = [
    (view.scrollLeft + screen[0]) / scale,
    (view.scrollTop + screen[1]) / scale,
  ];
  zoom = clamp(n, 1, 4);
  resize();
  view.scrollTo(doc[0] * scale - screen[0], doc[1] * scale - screen[1]);
  recordView();
  refresh();
}
function draw() {
  if (!paintFrame) paintFrame = requestAnimationFrame(paint);
}
function backgroundReady() {
  if (gesture?.type === "ink") gesture.viewKey = null;
  draw();
}
function paintLiveInk(g) {
  // Freeze completed portions of the preview. The full-resolution stroke is
  // fitted once at commit, using all original pressure and timing samples.
  function section(start, end) {
    const raw = g.raw.slice(start, end),
      times = g.times.slice(start, end);
    return new Path2D(
      inkPath(makeInk(smooth(raw, g.smoothing, times), g.color, g.id)),
    );
  }
  while (g.raw.length - g.previewStart > 100) {
    const end = g.previewStart + 96;
    g.prefix.addPath(section(g.previewStart, end + 1));
    g.previewStart = end;
  }
  const outline = new Path2D(g.prefix);
  outline.addPath(section(g.previewStart, g.raw.length));
  ctx.save();
  ctx.fillStyle = rgb(g.color);
  if (g.marker) {
    ctx.globalAlpha = g.prefs.opacity;
    ctx.globalCompositeOperation = "multiply";
  }
  ctx.fill(outline);
  ctx.restore();
}
function paint() {
  paintFrame = 0;
  if (!book || !sheet.width) return;
  const r = sheet.width / Math.max(1, view.clientWidth),
    s = r * scale,
    left = view.scrollLeft / scale,
    top = view.scrollTop / scale;
  const first = Math.max(0, Math.floor(top / H)),
    last = Math.min(
      pages - 1,
      Math.floor((top + view.clientHeight / scale) / H),
    );
  const live = gesture?.type === "ink" ? gesture : null;
  const viewKey = [left, top, s, sheet.width, sheet.height].join("/");
  if (live?.backdrop && live.viewKey === viewKey) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(live.backdrop, 0, 0);
    ctx.setTransform(s, 0, 0, s, -left * s, -top * s);
  } else {
    ctx.setTransform(s, 0, 0, s, -left * s, -top * s);
    ctx.fillStyle = "white";
    ctx.fillRect(
      left,
      top,
      view.clientWidth / scale,
      view.clientHeight / scale,
    );
    for (let n = first; n <= last; n++) {
      if (sourceIndex(book, n) != null) {
        const want = Math.min(
          2400,
          Math.max(850, Math.ceil((view.clientWidth * zoom * r) / 250) * 250),
        );
        const cached = pdfCache.get(n);
        if (cached?.img) drawPDFImage(ctx, cached.img, n);
        if (source && (!cached || cached.width < want) && !cached?.busy) {
          const hold = { ...cached, busy: true, width: want },
            doc = source;
          pdfCache.set(n, hold);
          pdfBitmap(
            doc,
            book.sourcePageMap?.[n] ?? n,
            want,
            book.originalPDFScale,
          )
            .then((img) => {
              if (doc !== source || pdfCache.get(n) !== hold) return;
              pdfCache.set(n, { img, width: want });
              for (const key of pdfCache.keys())
                if (Math.abs(n - key) > 3) pdfCache.delete(key);
              backgroundReady();
            })
            .catch((e) => {
              if (doc === source) {
                pdfCache.set(n, { width: want });
                notify(e.message);
              }
            });
        }
      } else paintPaper(ctx, n, paper(book, n));
    }
    const visible = [
      [left, top],
      [view.clientWidth / scale, view.clientHeight / scale],
    ];
    for (const o of book.objects)
      if (
        (o.id !== editing?.object.id || editing?.parent) &&
        overlaps(o.frame, visible)
      )
        paintObject(ctx, o, backgroundReady);
    if (live) {
      const buffer = live.backdrop ?? document.createElement("canvas");
      buffer.width = sheet.width;
      buffer.height = sheet.height;
      buffer.getContext("2d").drawImage(sheet, 0, 0);
      live.backdrop = buffer;
      live.viewKey = viewKey;
    }
  }
  if (live?.raw.length) paintLiveInk(live);
  ctx.strokeStyle = "#87969f";
  ctx.lineWidth = 1.15 / scale;
  ctx.beginPath();
  for (let n = Math.max(1, first); n <= last; n++) {
    ctx.moveTo(0, n * H);
    ctx.lineTo(W, n * H);
  }
  ctx.stroke();
  if (effective() === "selector" && selection.size) {
    const box = groupRect(selected());
    if (box) {
      const pad = 4 / scale,
        [[x, y], [w, h]] = box;
      const target = [
        [x - pad, y - pad],
        [w + 2 * pad, h + 2 * pad],
      ];
      ctx.strokeStyle = "#197c6f";
      ctx.lineWidth = 1 / scale;
      ctx.setLineDash([4 / scale, 3 / scale]);
      ctx.strokeRect(...target[0], ...target[1]);
      ctx.setLineDash([]);
      for (const p of corners(target)) {
        ctx.beginPath();
        ctx.arc(...p, 3.25 / scale, 0, Math.PI * 2);
        ctx.fillStyle = "white";
        ctx.fill();
        ctx.stroke();
      }
    }
  }
  for (const item of studyItems) {
    const [p, d] = item.frame;
    ctx.fillStyle = item.origin ? "#ffcd3516" : "#ffcc3638";
    ctx.fillRect(...p, ...d);
    ctx.strokeStyle = "#cf8125";
    ctx.lineWidth = 1 / scale;
    ctx.strokeRect(...p, ...d);
  }
  if (gesture?.preview) paintObject(ctx, gesture.preview);
  if (gesture?.guides) {
    ctx.strokeStyle = "#cc4282";
    ctx.lineWidth = 1 / scale;
    ctx.beginPath();
    for (const [a, b] of gesture.guides) {
      ctx.moveTo(...a);
      ctx.lineTo(...b);
    }
    ctx.stroke();
  }
  const code =
      selection.size === 1 && tool === "selector" ? selected()[0] : null,
    cb = $("code-toggle");
  cb.hidden = code?.codeStyle == null;
  if (!cb.hidden) {
    cb.style.left = (code.frame[0][0] + code.frame[1][0]) * scale + "px";
    cb.style.top = code.frame[0][1] * scale + "px";
    cb.title = code.codeStyle
      ? "Turn syntax colors off"
      : "Turn syntax colors on";
  }
  if (gesture?.type === "region" && gesture.points.length) {
    const poly = regionPolygon();
    ctx.beginPath();
    poly.forEach((p, i) => (i ? ctx.lineTo(...p) : ctx.moveTo(...p)));
    ctx.closePath();
    ctx.fillStyle = "#37877720";
    ctx.fill();
    ctx.strokeStyle = "#197c6f";
    ctx.lineWidth = 1 / scale;
    ctx.stroke();
  }
  if (stylusCursor && effective() === "eraser" && !lower) {
    ctx.beginPath();
    ctx.arc(...stylusCursor, settings().diameter / scale / 2, 0, Math.PI * 2);
    ctx.strokeStyle = "#536672";
    ctx.lineWidth = 1 / scale;
    ctx.stroke();
  }
}
new ResizeObserver(() => {
  if (book) {
    resize();
    refresh();
  }
}).observe(view);
view.addEventListener(
  "scroll",
  () => {
    if (!book) return;
    if (
      view.scrollTop + view.clientHeight >
      world.offsetHeight - view.clientHeight * 0.5
    ) {
      pages += 2;
      world.style.height = pages * H * scale + "px";
    }
    refresh();
    recordView();
  },
  { passive: true },
);
function pickTool(id) {
  erasingContact = false;
  studyItems = [];
  studySequence++;
  $("solve").disabled = false;
  $("solve").textContent = "Solve";
  finishText();
  finishGesture();
  armed = false;
  tool = id;
  closePop();
  sheet.focus({ preventScroll: true });
  refresh();
  recordView();
}
function scaledPressure(e, p) {
  let value = 1;
  if (e.pointerType === "pen" && devices[device][1])
    value = pressureResponse(p, e.pressure);
  return p.width * 0.5 * value;
}
function append(e, p, isUp = false) {
  const g = gesture,
    last = g.raw.at(-1);
  let radius = isUp && last ? last.radius : scaledPressure(e, g.prefs);
  if (!isUp && last && e.pointerType === "pen")
    radius = radius * 0.68 + last.radius * 0.32;
  if (g.marker) radius = g.prefs.markerWidth / 2;
  p = [
    clamp(p[0], radius, W - radius),
    clamp(p[1], radius, pages * H - radius),
  ];
  if (last && dist(last.position, p) < 0.12) {
    if (g.raw.length === 1) last.radius = Math.max(last.radius, radius);
    return;
  }
  g.raw.push({ position: p, radius });
  g.times.push(e.timeStamp * 0.001);
  liveInk = null;
  if (performance.now() - g.checkpoint > 800) {
    g.checkpoint = performance.now();
    touchSave();
  }
}
function currentInk() {
  if (!liveInk) {
    liveInk = makeInk(
      smooth(gesture.raw, gesture.smoothing, gesture.times),
      gesture.color,
      gesture.id,
    );
    if (gesture.marker) {
      liveInk.instrument = "marker";
      liveInk.opacity = settings().opacity;
    }
  }
  return liveInk;
}
function erase(p) {
  if (armed) erasingContact = true;
  const g = gesture,
    prev = g.last || p,
    r = settings().diameter / scale / 2;
  let changed = false;
  const next = book.objects.flatMap((o) => {
    const pieces = g.regular
      ? erasePart(o, prev, p, r)
      : touchesInk(o, prev, p, r)
        ? []
        : null;
    if (pieces === null) return [o];
    changed = true;
    return pieces;
  });
  if (changed) {
    book = { ...book, objects: next };
    g.changed = true;
  }
  g.last = p;
  draw();
}
function regionPolygon() {
  const g = gesture;
  return g.mode === "Rectangle"
    ? corners(rect(g.start, g.points.at(-1)))
    : g.points;
}
function begin(p, e) {
  const item = studyItems.find((i) => contains(i.frame, p, 2 / scale));
  if (item) {
    openPop($("solve"), "study", "Solve", () => studyContent(pop, item));
    return;
  }
  finishText();
  closePop();
  const mode = effective(),
    prefs = settings();
  if (mode === "brush" || mode === "marker") {
    gesture = {
      type: "ink",
      prefs,
      previewStart: 0,
      prefix: new Path2D(),
      marker: mode === "marker",
      id: uid(),
      raw: [],
      times: [],
      color: mode === "marker" ? markers[prefs.markerInk] : color(),
      smoothing: prefs.smoothing,
      checkpoint: performance.now(),
    };
    liveInk = null;
    append(e, p);
  } else if (
    mode === "eraser" &&
    (armed || ["Regular", "Stroke"].includes(prefs.erase))
  ) {
    gesture = {
      type: "erase",
      regular: prefs.erase === "Regular",
      before: book.objects,
    };
    erase(p);
  } else if (mode === "shapes" || mode === "table") {
    const table =
      mode === "table" &&
      [...book.objects].reverse().find((o) => o.table && contains(o.frame, p));
    if (table) {
      const i = table.table.cells.findIndex((_, i) =>
        contains(cellFrame(table, i), p),
      );
      if (i >= 0) startCell(table, i);
      return;
    }
    gesture = { type: mode, start: p };
    move(p, e);
  } else if (mode === "text") {
    const old = [...book.objects]
      .reverse()
      .find((o) => kind(o) === "text" && hit(o, p, 1 / scale));
    if (old?.table) {
      const i = old.table.cells.findIndex((_, i) =>
        contains(cellFrame(old, i), p),
      );
      if (i >= 0) startCell(old, i);
    } else startText(p, old);
    return;
  } else {
    const box =
      mode === "selector" && selection.size ? groupRect(selected()) : null;
    if (box && !e.shiftKey) {
      const [[x, y], [w, h]] = box,
        pad = 4 / scale,
        handles = corners([
          [x - pad, y - pad],
          [w + 2 * pad, h + 2 * pad],
        ]);
      const i = handles.findIndex((q) => dist(p, q) < 8 / scale);
      if (i >= 0) {
        gesture = {
          type: "resize",
          start: p,
          anchor: corners(box)[(i + 2) % 4],
          box,
          before: book.objects,
        };
        draw();
        return;
      }
      if (contains(box, p, pad)) {
        gesture = { type: "move", start: p, box, before: book.objects };
        draw();
        return;
      }
    }
    const shape = mode === "eraser" ? prefs.erase : prefs.select;
    if (mode === "selector" && shape === "Tap" && !e.shiftKey) {
      const hitObject = [...book.objects]
        .reverse()
        .find((o) => inFilter(o) && hit(o, p, 3.5 / scale));
      if (hitObject) {
        selection = new Set([hitObject.id]);
        gesture = {
          type: "move",
          start: p,
          box: hitObject.frame,
          before: book.objects,
        };
        refresh();
        return;
      }
    }
    gesture = {
      type: "region",
      erase: mode === "eraser",
      mode: shape,
      start: p,
      points: [p],
      previous: e.shiftKey ? new Set(selection) : new Set(),
    };
  }
  draw();
}
function move(p, e) {
  const g = gesture;
  if (!g) return;
  if (g.type === "shapes")
    g.preview = shapeObject(
      g.start,
      p,
      settings().shape,
      e.shiftKey || settings().constrain,
      settings().shapeWidth,
      color(),
    );
  if (g.type === "table") {
    const s = settings(),
      f =
        dist(g.start, p) < 4 / scale
          ? [[...g.start], [s.tableWidth, s.tableHeight]]
          : rect(g.start, p);
    f[1] = [clamp(f[1][0], 36, W), clamp(f[1][1], 18, H)];
    f[0][0] = clamp(f[0][0], 0, W - f[1][0]);
    g.preview = {
      id: (g.id ??= uid()),
      frame: f,
      table: tableGrid(s.rows, s.columns, s.header),
      content: { text: { _0: "", _1: inks[0], _2: 11 } },
    };
  }
  if (g.type === "ink") append(e, p);
  if (g.type === "erase") erase(p);
  if (g.type === "region") {
    if (g.mode === "Rectangle") g.points = [g.start, p];
    else if (dist(g.points.at(-1), p) > 1 / scale) g.points.push(p);
  }
  if (g.type === "move" || g.type === "resize") {
    const [[x, y], [w, h]] = g.box;
    let dx = 0,
      dy = 0,
      k = 1,
      anchor = [0, 0];
    if (g.type === "move") {
      dx = clamp(p[0] - g.start[0], -x, W - x - w);
      dy = Math.max(-y, p[1] - g.start[1]);
      g.guides = [];
      if (settings().guides && (Math.abs(dx) + Math.abs(dy)) * scale > 2) {
        const visible = [
          [view.scrollLeft / scale, view.scrollTop / scale],
          [view.clientWidth / scale, view.clientHeight / scale],
        ];
        g.targets ??= g.before
          .filter((o) => !selection.has(o.id) && overlaps(o.frame, visible))
          .map((o) => o.frame);
        const a = align(
          [
            [x + dx, y + dy],
            [w, h],
          ],
          g.targets,
          4 / scale,
        );
        dx = clamp(dx + a.adjust[0], -x, W - x - w);
        dy = Math.max(-y, dy + a.adjust[1]);
        g.guides = a.guides;
      }
    } else {
      anchor = g.anchor;
      const t =
        selection.size === 1
          ? g.before.find((o) => selection.has(o.id) && o.table)
          : null;
      if (t) {
        const left = anchor[0] >= x + w,
          top = anchor[1] >= y + h;
        const width = clamp(
          w + (p[0] - g.start[0]) * (left ? -1 : 1),
          36,
          left ? anchor[0] : W - anchor[0],
        );
        const height = clamp(
          h + (p[1] - g.start[1]) * (top ? -1 : 1),
          18,
          top ? Math.min(H, anchor[1]) : H,
        );
        g.changed = width !== w || height !== h;
        book = {
          ...book,
          objects: g.before.map((o) =>
            o.id === t.id
              ? {
                  ...o,
                  layoutFrame: undefined,
                  frame: [
                    [
                      left ? anchor[0] - width : anchor[0],
                      top ? anchor[1] - height : anchor[1],
                    ],
                    [width, height],
                  ],
                }
              : o,
          ),
        };
        draw();
        return;
      }
      const u = g.start.map((v, i) => v - anchor[i]),
        v = p.map((q, i) => q - anchor[i]);
      let max = 30;
      if (x < anchor[0]) max = Math.min(max, anchor[0] / (anchor[0] - x));
      if (x + w > anchor[0])
        max = Math.min(max, (W - anchor[0]) / (x + w - anchor[0]));
      if (y < anchor[1]) max = Math.min(max, anchor[1] / (anchor[1] - y));
      k = clamp(
        (u[0] * v[0] + u[1] * v[1]) / Math.max(0.001, u[0] ** 2 + u[1] ** 2),
        0.07,
        max,
      );
    }
    g.changed = !!(dx || dy || Math.abs(k - 1) > 0.001);
    book = {
      ...book,
      objects: g.changed
        ? g.before.map((o) =>
            selection.has(o.id) ? transform(o, anchor, k, dx, dy) : o,
          )
        : g.before,
    };
  }
  draw();
}
function finishGesture(p) {
  const g = gesture;
  if (!g) return;
  let next, before;
  if (g.type === "ink" && g.raw.length) {
    next = [...book.objects, currentInk()];
  } else if (g.preview) {
    next = [...book.objects, g.preview];
    if (g.type === "table") {
      tool = "selector";
      selection = new Set([g.preview.id]);
    }
  } else if (g.type === "region") {
    const end = p || g.points.at(-1),
      poly = regionPolygon();
    const isTap =
      g.mode === "Tap" ||
      (dist(g.start, end) < 4 / scale && g.points.length < 3);
    const eligible = (o) => (g.erase ? kind(o) === "ink" : inFilter(o));
    const hits = isTap
      ? [...book.objects]
          .reverse()
          .filter((o) => eligible(o) && hit(o, end, 4 / scale))
          .slice(0, 1)
      : book.objects.filter((o) => eligible(o) && regionHit(o, poly));
    if (g.erase) {
      const ids = new Set(hits.map((o) => o.id));
      if (ids.size) next = book.objects.filter((o) => !ids.has(o.id));
    } else {
      selection = g.previous;
      for (const o of hits) {
        if (isTap && selection.has(o.id)) selection.delete(o.id);
        else selection.add(o.id);
      }
    }
  } else if (g.changed) {
    before = g.before;
    next = book.objects;
  }
  gesture = null;
  liveInk = null;
  if (next)
    setObjects(
      next,
      g.type === "ink"
        ? "Brush stroke"
        : g.type === "region" || g.type === "erase"
          ? "Erase"
          : "Transform",
      before || book.objects,
    );
  else refresh();
  recordView();
}
function penPan(dy) {
  panRemainder += clamp(dy, -75, 75) * settings().scroll;
  if (!panFrame) {
    const step = () => {
      const n = panRemainder * 0.43;
      panRemainder -= n;
      view.scrollTop += n;
      if (Math.abs(panRemainder) > 0.15) panFrame = requestAnimationFrame(step);
      else {
        panFrame = 0;
        panRemainder = 0;
      }
    };
    panFrame = requestAnimationFrame(step);
  }
}
function capture(id) {
  try {
    sheet.setPointerCapture(id);
  } catch {}
}
let panY = 0,
  erasingContact = false;
function liftEraser() {
  if (armed && erasingContact) {
    armed = false;
    tool = "brush";
  }
  erasingContact = false;
}
function barrel(e) {
  if (e.pointerType === "touch") return false;
  const buttons = devices[device][2];
  const hi = buttons > 0 && ((e.buttons & 2) !== 0 || (e.buttons & 32) !== 0);
  const lo = buttons > 1 && (e.buttons & 4) !== 0;
  if (hi && !upper && !lo) {
    if (gesture?.type === "ink") finishGesture();
    armed = true;
    if (penContact !== null && e.buttons & 1) {
      gesture = {
        type: "erase",
        regular: settings().erase === "Regular",
        before: book.objects,
      };
      erase(point(e));
    }
    refresh();
  }
  upper = hi;
  if (lo && !lower) {
    finishGesture();
    lower = true;
    panY = e.clientY;
    ignoreContact = !!(e.buttons & 1);
    capture(e.pointerId);
  } else if (lo) {
    penPan(panY - e.clientY);
    panY = e.clientY;
    if (e.buttons & 1) ignoreContact = true;
  } else if (lower) {
    lower = false;
    if (!(e.buttons & 1)) ignoreContact = false;
  }
  if (!e.buttons && e.type === "pointermove" && penContact !== null) {
    finishGesture(point(e));
    penContact = null;
    liftEraser();
    ignoreContact = false;
    refresh();
  }
  return lo || (hi && !(e.buttons & 1)) || e.button === 1 || e.button === 2;
}
function touchMetrics() {
  const pts = [...touches.values()],
    a = pts[0],
    b = pts[1] || a;
  return {
    x: (a[0] + b[0]) / 2,
    y: (a[1] + b[1]) / 2,
    d: Math.max(1, dist(a, b)),
  };
}
function touchBegin(e) {
  if (penContact !== null) return true;
  touches.set(e.pointerId, [e.clientX, e.clientY]);
  capture(e.pointerId);
  if (touches.size >= 2 || !fingerWrites()) {
    if (gesture?.type === "ink") {
      gesture = null;
      liveInk = null;
      touchSave();
    }
    const m = touchMetrics(),
      r = view.getBoundingClientRect();
    touchGesture = {
      ...m,
      tap: touches.size === 1 && !fingerWrites(),
      z: zoom,
      anchor: [
        (view.scrollLeft + m.x - r.left) / scale,
        (view.scrollTop + m.y - r.top) / scale,
      ],
    };
    return true;
  }
  return false;
}
function touchMove(e) {
  if (!touches.has(e.pointerId)) return true;
  touches.set(e.pointerId, [e.clientX, e.clientY]);
  if (!touchGesture) return false;
  const m = touchMetrics(),
    r = view.getBoundingClientRect();
  if (Math.hypot(m.x - touchGesture.x, m.y - touchGesture.y) > 6)
    touchGesture.tap = false;
  if (touches.size >= 2) {
    zoom = clamp((touchGesture.z * m.d) / touchGesture.d, 1, 4);
    resize();
  }
  view.scrollTo(
    touchGesture.anchor[0] * scale - (m.x - r.left),
    touchGesture.anchor[1] * scale - (m.y - r.top),
  );
  refresh();
  return true;
}
sheet.onpointerdown = (e) => {
  if (!book) return;
  observePointer(e);
  e.preventDefault();
  closePop();
  if (e.pointerType === "touch" && touchBegin(e)) return;
  if (e.pointerType === "pen" && e.button === 5) {
    armed = true;
    penContact = e.pointerId;
    capture(e.pointerId);
    begin(point(e), e);
    refresh();
    return;
  }
  const handled = barrel(e);
  if (handled) return;
  if (e.button !== 0 && e.button !== 5) return;
  if (e.pointerType === "pen") {
    penContact = e.pointerId;
    touches.clear();
    touchGesture = null;
  }
  if (space) {
    finishGesture();
    gesture = { type: "pan", last: e.clientY };
    capture(e.pointerId);
    refresh();
    return;
  }
  capture(e.pointerId);
  begin(point(e), e);
};
sheet.onpointermove = (e) => {
  if (!book) return;
  if (e.pointerType === "touch" && touchMove(e)) return;
  if (
    e.pointerType === "pen" &&
    e.button === 0 &&
    !(e.buttons & 1) &&
    !(e.buttons & 32) &&
    e.pointerId === penContact
  ) {
    finishGesture(point(e));
    penContact = null;
    liftEraser();
    refresh();
    return;
  }
  if (
    e.buttons & 32 &&
    penContact === e.pointerId &&
    gesture?.type === "erase"
  ) {
    erase(point(e));
    return;
  }
  if (barrel(e) || ignoreContact) return;
  if (gesture?.type === "pan") {
    penPan(gesture.last - e.clientY);
    gesture.last = e.clientY;
    return;
  }
  stylusCursor = point(e);
  if (gesture && e.buttons & 1) {
    const samples = e.getCoalescedEvents?.() || [];
    for (const sample of samples.length ? samples : [e])
      move(point(sample), sample);
  } else if (effective() === "eraser") draw();
};
sheet.onpointerup = (e) => {
  if (!book) return;
  if (e.pointerType === "touch") {
    if (penContact !== null) return;
    touches.delete(e.pointerId);
    if (touchGesture) {
      const tap =
        touchGesture.tap &&
        !touches.size &&
        Math.hypot(e.clientX - touchGesture.x, e.clientY - touchGesture.y) <= 6;
      touchGesture = null;
      const p = point(e);
      if (
        tap &&
        (studyItems.some((i) => contains(i.frame, p, 2 / scale)) ||
          ["text", "selector"].includes(effective()) ||
          (effective() === "table" &&
            book.objects.some((o) => o.table && contains(o.frame, p))))
      ) {
        begin(p, e);
        finishGesture(p);
        refresh();
      }
      if (touches.size) {
        const m = touchMetrics(),
          r = view.getBoundingClientRect();
        touchGesture = {
          ...m,
          z: zoom,
          anchor: [
            (view.scrollLeft + m.x - r.left) / scale,
            (view.scrollTop + m.y - r.top) / scale,
          ],
        };
      }
      return;
    }
  }
  const sideOnly =
    (e.button === 1 || e.button === 2) && penContact === null && !gesture;
  barrel(e);
  if (sideOnly) {
    refresh();
    return;
  }
  if (["shapes", "table", "move", "resize"].includes(gesture?.type))
    move(point(e), e);
  if (gesture?.type === "ink") append(e, point(e), true);
  else if (gesture?.type === "erase") erase(point(e));
  finishGesture(point(e));
  liftEraser();
  ignoreContact = false;
  penContact = null;
  refresh();
};
sheet.onpointercancel = (e) => {
  if (penContact !== null && e.pointerId !== penContact) {
    touches.delete(e.pointerId);
    return;
  }
  finishGesture();
  endTransient();
  refresh();
};
sheet.onpointerleave = () => {
  stylusCursor = null;
  draw();
};
sheet.oncontextmenu = (e) => e.preventDefault();
view.addEventListener(
  "wheel",
  (e) => {
    if (e.ctrlKey) {
      e.preventDefault();
      const r = view.getBoundingClientRect();
      setZoom(zoom * Math.exp(-e.deltaY * 0.01), [
        e.clientX - r.left,
        e.clientY - r.top,
      ]);
    }
  },
  { passive: false },
);
function textObject(base, value, p, size, c) {
  const width = base?.frame[1][0] ?? Math.min(290, W - p[0] - 3);
  const lines = value.split("\n");
  const height = editing
    ? Math.max(24, editor.scrollHeight / scale)
    : Math.max(24, lines.length * size * 1.2 + 8);
  let style = base?.codeStyle;
  if (style == null) {
    const [source, code] = recognizeCode(value);
    if (code) {
      style = true;
      value = source;
    }
  }
  let measured = height;
  if (style != null) {
    const probe = sheet.getContext("2d");
    probe.save();
    probe.font = size + "px ui-monospace, Menlo, monospace";
    const cols = Math.max(
      1,
      Math.floor((width - 10) / probe.measureText("M").width),
    );
    probe.restore();
    measured =
      8 +
      size *
        1.22 *
        value
          .split("\n")
          .reduce(
            (n, line) =>
              n +
              Math.max(1, Math.ceil(line.replace(/\t/g, "    ").length / cols)),
            0,
          );
  }
  return {
    ...base,
    codeStyle: style,
    id: base?.id || uid(),
    alignment: base?.alignment || settings().alignment,
    frame: [p, [width, measured]],
    content: { text: { _0: value, _1: c, _2: size } },
  };
}
function placeEditor() {
  if (!editing) return;
  const o = editing.object,
    [[x, y], [w]] = o.frame;
  Object.assign(editor.style, {
    left: x * scale + "px",
    top: y * scale + "px",
    width: w * scale + "px",
    fontFamily:
      o.codeStyle != null ? "ui-monospace, Menlo, monospace" : "inherit",
    fontSize: o.content.text._2 * scale + "px",
    color: rgb(o.content.text._1),
    textAlign:
      { Auto: "start", Left: "left", Right: "right", Center: "center" }[
        o.alignment
      ] || "start",
    height: "auto",
  });
  editor.style.height =
    (editing?.parent
      ? o.frame[1][1] * scale
      : Math.max(24 * scale, editor.scrollHeight + 2)) + "px";
}
function startText(p, old, caret, length = 0) {
  const prefs = settings(),
    at = [clamp(p[0], 4, W - 94), Math.max(0, p[1])],
    o = old || textObject(null, "", at, prefs.textSize, inks[prefs.textInk]);
  if (!old && prefs.code) o.codeStyle = true;
  editing = { object: o, existing: !!old };
  selection.clear();
  editor.value = o.content.text._0;
  editor.hidden = false;
  editor.dir = "auto";
  placeEditor();
  editor.focus({ preventScroll: true });
  editor.setSelectionRange(
    caret ?? editor.value.length,
    (caret ?? editor.value.length) + length,
  );
  recordView();
  draw();
}
function startCell(o, i, caret, length = 0) {
  const frame = cellFrame(o, i),
    proxy = {
      id: o.id,
      frame,
      content: {
        text: {
          ...o.content.text,
          _0: o.table.cells[i],
          _2: Math.min(o.content.text._2, frame[1][1] * 0.64),
        },
      },
    };
  startText(frame[0], proxy, caret, length);
  editing.parent = o;
  editing.cell = i;
  placeEditor();
  recordView();
}
function finishText(cancel = false) {
  if (!editing) return;
  const e = editing,
    value = editor.value;
  const next = snapshot().objects;
  editing = null;
  editor.hidden = true;
  editor.blur();
  sheet.focus({ preventScroll: true });
  if (!cancel && value !== e.object.content.text._0)
    setObjects(next, "Edit text");
  else if (cancel) {
    touchSave();
  }
  if (e.parent) selection = new Set([e.parent.id]);
  recordView();
  draw();
}
editor.oninput = () => {
  placeEditor();
  touchSave();
  recordView();
};
editor.onselect = () => recordView();
function replaceObjects(objects, label) {
  finishText();
  finishGesture();
  setObjects([...book.objects, ...objects], label);
  tool = "selector";
  selection = new Set(objects.map((o) => o.id));
  refresh();
}
function insertion() {
  return [
    clamp(Math.max(4.6 * G, view.scrollLeft / scale + 18), 0, W - 110),
    view.scrollTop / scale + Math.min(50, (view.clientHeight / scale) * 0.15),
  ];
}
async function insertImage(file, onPage = null) {
  const url = URL.createObjectURL(file),
    img = new Image();
  try {
    img.src = url;
    await img.decode();
    const ratio = Math.min(
        1,
        4800 / Math.max(img.naturalWidth, img.naturalHeight),
      ),
      c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(img.naturalWidth * ratio));
    c.height = Math.max(1, Math.round(img.naturalHeight * ratio));
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    const f = Math.min(
        0.6,
        Math.min(W * 0.78, Math.max(180, view.clientWidth / scale - 28)) /
          c.width,
        (H * 0.78) / c.height,
      ),
      p = insertion();
    p[0] = Math.min(p[0], W - c.width * f);
    if (onPage !== null) {
      const top = onPage * H,
        last = book.objects
          .filter((o) => o.frame[0][1] >= top && o.frame[0][1] < top + H)
          .reduce(
            (m, o) => Math.max(m, o.frame[0][1] + o.frame[1][1]),
            top + 2 * G,
          );
      const maxY = top + H - c.height * f - 2 * G;
      const shownTop = clamp(view.scrollTop / scale + 2 * G, top + 2 * G, maxY);
      p[0] = clamp((W - c.width * f) / 2, 4 * G + 3, W - c.width * f - G);
      p[1] = last + G <= maxY ? Math.max(shownTop, last + G) : shownTop;
      if (
        p[1] < view.scrollTop / scale ||
        p[1] > (view.scrollTop + view.clientHeight) / scale - 30
      )
        view.scrollTop = Math.max(0, (p[1] - G) * scale);
    }
    replaceObjects(
      [
        {
          id: uid(),
          frame: [p, [c.width * f, c.height * f]],
          content: { image: { _0: c.toDataURL("image/png").split(",")[1] } },
        },
      ],
      "Insert image",
    );
  } finally {
    URL.revokeObjectURL(url);
  }
}
let clipObjects = [];
function copySelection(e) {
  if (!selection.size) return false;
  clipObjects = selected();
  const value = JSON.stringify(clipObjects);
  if (e?.clipboardData) {
    e.clipboardData.setData("application/x-gridnote-objects", value);
    e.clipboardData.setData(
      "text/plain",
      clipObjects.length === 1 && kind(clipObjects[0]) === "text"
        ? clipObjects[0].content.text._0
        : "Gridnote selection",
    );
    e.preventDefault();
  }
  return true;
}
function pasteCopies(items) {
  if (!items?.length) return;
  const box = groupRect(items),
    [[x, y], [w, h]] = box,
    p = insertion(),
    visible = [
      [view.scrollLeft / scale, view.scrollTop / scale],
      [view.clientWidth / scale, view.clientHeight / scale],
    ];
  const nearPage = overlaps(box, visible),
    dx = clamp(nearPage ? x + 12 : p[0], 0, W - w) - x,
    dy = (nearPage ? y + 12 : p[1]) - y;
  replaceObjects(
    items.map((o) => ({ ...transform(o, [0, 0], 1, dx, dy), id: uid() })),
    "Paste selection",
  );
}
function deleteSelection(inkOnly = false) {
  if (!selection.size) return;
  const next = book.objects.filter(
    (o) => !selection.has(o.id) || (inkOnly && kind(o) !== "ink"),
  );
  if (next.length !== book.objects.length) setObjects(next, "Delete selection");
  selection = new Set(next.filter((o) => selection.has(o.id)).map((o) => o.id));
  refresh();
}
function isEntry(target) {
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement ||
    target?.isContentEditable
  );
}
document.addEventListener("copy", (e) => {
  if (book && !isEntry(e.target)) copySelection(e);
});
document.addEventListener("cut", (e) => {
  if (book && !isEntry(e.target) && copySelection(e)) deleteSelection();
});
document.addEventListener("paste", (e) => {
  if (!book || isEntry(e.target)) return;
  const data = e.clipboardData;
  const own = data.getData("application/x-gridnote-objects");
  if (own) {
    e.preventDefault();
    run(() => pasteCopies(JSON.parse(own)));
    return;
  }
  const images = [...data.items]
    .filter((i) => i.type.startsWith("image/"))
    .map((i) => i.getAsFile())
    .filter(Boolean);
  if (images.length) {
    e.preventDefault();
    run(async () => {
      for (const img of images) await insertImage(img);
    });
    return;
  }
  const str = data.getData("text/plain");
  if (str) {
    e.preventDefault();
    if (str === "Gridnote selection" && clipObjects.length)
      pasteCopies(clipObjects);
    else {
      const [value, code] = recognizeCode(str);
      startText(insertion());
      if (code) editing.object.codeStyle = true;
      editor.value = value;
      placeEditor();
      finishText();
    }
  }
});
sheet.ondragover = (e) => e.preventDefault();
sheet.ondrop = (e) => {
  e.preventDefault();
  run(async () => {
    for (const file of e.dataTransfer.files) {
      if (file.type.startsWith("image/")) await insertImage(file);
      else await importBook(file);
    }
  });
};
function closePop() {
  pop.hidden = true;
  popupKind = "";
}
function openPop(anchor, type, heading, build) {
  pop.oninput = null;
  pop.replaceChildren($el("h2", heading));
  popupKind = type;
  build();
  pop.hidden = false;
  const r = anchor.getBoundingClientRect(),
    pw = pop.offsetWidth,
    ph = pop.offsetHeight;
  pop.style.left = clamp(r.left, 5, innerWidth - pw - 5) + "px";
  pop.style.top =
    (r.bottom + ph + 6 < innerHeight
      ? r.bottom + 4
      : Math.max(5, r.top - ph - 5)) + "px";
}
function choices(label, items, value, select) {
  if (label) pop.append($el("small", label));
  const row = $el("div");
  row.className = "choices";
  items.forEach((item) => {
    const b = button(item, () => {
      select(item);
      for (const el of row.children) el.classList.toggle("active", el === b);
      refresh();
    });
    b.classList.toggle("active", value === item);
    row.append(b);
  });
  pop.append(row);
}
function slider(label, key, min, max, step, format) {
  const row = $el("label");
  row.className = "field";
  const output = $el("output", format(settings()[key])),
    input = $el("input");
  input.type = "range";
  input.min = min;
  input.max = max;
  input.step = step;
  input.value = settings()[key];
  input.setAttribute("aria-label", label);
  input.oninput = () => {
    setting(key, Number(input.value));
    output.textContent = format(Number(input.value));
    draw();
  };
  row.append(document.createTextNode(label), output, input);
  pop.append(row);
}
function swatches(container, values, current, onClick, names) {
  const row = $el("div");
  row.className = "choices";
  for (const [i, c] of values.entries()) {
    const b = button(
      "",
      () => {
        onClick(i);
        for (const child of row.children)
          child.setAttribute("aria-pressed", String(child === b));
      },
      "swatch",
    );
    b.style.setProperty("--swatch", c);
    b.title = names[i];
    b.setAttribute("aria-label", names[i]);
    b.setAttribute("aria-pressed", String(i === current));
    row.append(b);
  }
  container.append(row);
}
function penColors() {
  const prefs = settings(),
    marker = tool === "marker",
    key = marker ? "markerInk" : tool === "text" ? "textInk" : "ink";
  swatches(
    pop,
    (marker ? markers : inks).map(rgb),
    prefs[key],
    (i) => {
      setting(key, i);
      refresh();
    },
    marker ? markerNames : inkNames,
  );
}
function checkOption(label, checked, change) {
  const l = $el("label"),
    c = $el("input");
  c.type = "checkbox";
  c.checked = checked;
  c.onchange = () => change(c.checked);
  l.append(c, document.createTextNode(label));
  pop.append(l);
  return c;
}
function tableOptions() {
  const o = selection.size === 1 ? selected()[0] : null,
    old = o?.table,
    s = settings(),
    row = $el("div");
  row.className = "table-options";
  pop.append(row);
  const values = {
    rows: old?.rows ?? s.rows,
    columns: old?.columns ?? s.columns,
    tableWidth: old ? o.frame[1][0] : s.tableWidth,
    tableHeight: old ? o.frame[1][1] : s.tableHeight,
    header: old?.header ?? s.header,
  };
  const change = (key, val) => {
    values[key] = val;
    setting(key, val);
    if (old) {
      const current = book.objects.find((x) => x.id === o.id),
        { rows, columns, header, tableWidth: w, tableHeight: h } = values;
      const next = {
        ...current,
        layoutFrame: undefined,
        frame: [
          [clamp(current.frame[0][0], 0, W - w), current.frame[0][1]],
          [w, h],
        ],
        table: tableGrid(rows, columns, header, current.table),
      };
      setObjects(
        book.objects.map((x) => (x.id === o.id ? next : x)),
        "Change table",
      );
    }
  };
  for (const [key, label, min, max] of [
    ["rows", "Rows", 1, 40],
    ["columns", "Columns", 1, 16],
    ["tableWidth", "Width (pt)", 36, Math.floor(W)],
    ["tableHeight", "Height (pt)", 18, Math.floor(H)],
  ]) {
    const l = $el("label", label),
      n = $el("input");
    n.type = "number";
    n.min = min;
    n.max = max;
    n.value = Math.round(values[key]);
    n.onchange = () => {
      const v = clamp(Math.round(Number(n.value) || min), min, max);
      n.value = v;
      change(key, v);
    };
    l.append(n);
    row.append(l);
  }
  checkOption("Header row", values.header, (v) => change("header", v));
}
function toolOptions(anchor, id) {
  openPop(anchor, "tool", toolNames[id][0], () => {
    const p = settings();
    if (id === "brush") {
      const sample = $el("canvas");
      sample.width = 480;
      sample.height = 54;
      sample.className = "nib-sample";
      sample.setAttribute("aria-label", "Stroke preview");
      pop.append(sample);
      function showSample() {
        const s = settings(),
          ctx = sample.getContext("2d");
        ctx.fillStyle = "#f8f7f1";
        ctx.fillRect(0, 0, sample.width, sample.height);
        ctx.fillStyle = rgb(inks[s.ink]);
        for (let x = 10; x < 470; x += 0.5) {
          const t = (x - 10) / 460,
            force = 0.1 + 0.9 * Math.sin(Math.PI * t);
          ctx.beginPath();
          ctx.arc(
            x,
            27 + 10 * Math.sin(t * Math.PI * 3),
            s.width * (devices[device][1] ? pressureResponse(s, force) : 1),
            0,
            2 * Math.PI,
          );
          ctx.fill();
        }
      }
      showSample();
      pop.oninput = () => queueMicrotask(showSample);
      choices("Writing tip", ["Pen", "Brush", "Fineliner"], p.nib, (v) => {
        setting("nib", v);
        toolOptions(anchor, id);
      });
      const supported = devices[device][1] && p.nib !== "Fineliner";
      const toggle = checkOption(
        "Use pen pressure",
        supported && p.usePressure,
        (v) => {
          setting("usePressure", v);
          toolOptions(anchor, id);
        },
      );
      toggle.disabled = !supported;
      slider("Width", "width", 0.7, 6, 0.1, (x) => x.toFixed(1) + " pt");
      slider(
        "Smoothing",
        "smoothing",
        0,
        1,
        0.01,
        (x) => Math.round(x * 100) + "%",
      );
      if (supported && p.usePressure)
        slider(
          "Pressure response",
          "pressure",
          0.5,
          2,
          0.01,
          (x) => x.toFixed(2) + "×",
        );
    }
    if (id === "marker") {
      slider("Width", "markerWidth", 3, 24, 0.5, (x) => x + " pt");
      slider(
        "Opacity",
        "opacity",
        0.12,
        0.75,
        0.01,
        (x) => Math.round(100 * x) + "%",
      );
    }
    if (id === "shapes") {
      choices("Shape", ["Line", "Arrow", "Box", "Oval"], p.shape, (x) =>
        setting("shape", x),
      );
      checkOption("Constrain angles and proportions", p.constrain, (v) =>
        setting("constrain", v),
      );
      slider(
        "Line width",
        "shapeWidth",
        0.7,
        6,
        0.1,
        (x) => x.toFixed(1) + " pt",
      );
    }
    if (id === "table") tableOptions();
    if (id === "selector") {
      if (selection.size === 1 && selected()[0]?.table) tableOptions();
      checkOption("Alignment guides", p.guides, (v) => setting("guides", v));
      choices("Selection shape", ["Tap", "Rectangle", "Lasso"], p.select, (x) =>
        setting("select", x),
      );
      pop.append($el("small", "Include in selection"));
      const row = $el("div");
      row.className = "choices";
      ["Ink", "Text", "Images"].forEach((n, i) => {
        const label = $el("label"),
          input = $el("input");
        input.type = "checkbox";
        const mask = 1 << i;
        input.checked = !!(p.mask & mask);
        input.onchange = () => {
          setting(
            "mask",
            input.checked ? settings().mask | mask : settings().mask & ~mask,
          );
          selection = new Set(
            selected()
              .filter(inFilter)
              .map((o) => o.id),
          );
          refresh();
        };
        label.append(input, document.createTextNode(n));
        row.append(label);
      });
      pop.append(row);
    }
    if (id === "eraser") {
      choices(
        "Eraser mode",
        ["Regular", "Stroke", "Rectangle", "Lasso"],
        p.erase,
        (x) => setting("erase", x),
      );
      slider("Contact diameter", "diameter", 6, 36, 1, (x) => x + " pt");
    }
    if (id === "text") {
      checkOption("Insert code block", p.code, (v) => setting("code", v));
      slider("Type size", "textSize", 8, 36, 1, (x) => x + " pt");
      choices(
        "Alignment",
        ["Auto", "Left", "Center", "Right"],
        p.alignment,
        (x) => setting("alignment", x),
      );
    }
    if (
      ["brush", "text", "marker", "shapes"].includes(id) &&
      ($("inks").hidden || getComputedStyle($("inks")).display === "none")
    )
      penColors();
    menuAction("Restore tool defaults", () => {
      restore(id);
      refresh();
      toolOptions(anchor, id);
    });
  });
}
function menuAction(label, action, enabled = true) {
  const item = button(
    label,
    () => {
      closePop();
      run(action);
    },
    "menu-item",
  );
  item.disabled = !enabled;
  pop.append(item);
}
$("subjects").onclick = () => {
  if (major() === "None") return;
  openPop($("subjects"), "subjects", "Study tools", () => {
    const frame = $el("iframe");
    frame.title = "Study tools";
    frame.src = "./subjects.html#" + encodeURIComponent(major());
    frame.className = "subject-frame";
    frame.dataset.major = major();
    pop.append(frame);
  });
};
window.addEventListener("message", (e) => {
  const frame = pop.querySelector("iframe.subject-frame");
  if (
    !book ||
    pop.hidden ||
    !frame ||
    e.origin !== location.origin ||
    e.source !== frame.contentWindow ||
    e.data?.type !== "gridnote-study-result" ||
    typeof e.data.text !== "string" ||
    e.data.text.length > 4096
  )
    return;
  closePop();
  startText(insertion());
  editing.object.codeStyle = null;
  editor.value = e.data.text;
  placeEditor();
  finishText();
});
function settingsMenu() {
  openPop($("settings"), "device", "Writing controls", () => {
    pop.append($el("small", deviceLabel()));
    const label = $el("label", "Major"),
      select = $el("select");
    select.setAttribute("aria-label", "Major");
    for (const name of majors) select.append($el("option", name));
    select.value = major();
    select.onchange = () => {
      chooseMajor(select.value);
      refresh();
    };
    label.append(select);
    pop.append(label);
    if (mobileSurface)
      checkOption("Write with finger", fingerWrites(), useFinger);
    if (devices[device][2] || !matchMedia("(pointer:coarse)").matches)
      slider(
        "Pen scroll speed",
        "scroll",
        0.12,
        0.65,
        0.01,
        (x) => x.toFixed(2) + "×",
      );
    pop.append($el("p", deviceHelp()));
    menuAction("Restore all settings", () => {
      restore();
      refresh();
      settingsMenu();
    });
  });
}
function paperMenu() {
  const n = currentPage();
  if (sourceIndex(book, n) != null) paperScope = "default";
  openPop($("paper"), "paper", "Paper", () => {
    choices(
      "",
      sourceIndex(book, n) != null
        ? ["Notebook default"]
        : ["This page", "Notebook default"],
      paperScope === "page" ? "This page" : "Notebook default",
      (x) => {
        paperScope = x === "This page" ? "page" : "default";
        paperMenu();
      },
    );
    const design =
      paperScope === "page"
        ? paper(book, n)
        : book.defaultPaper || defaultPaper;
    choices("Ruling", rulings, design.ruling, (x) => {
      changePaper({ ...design, ruling: x });
      paperMenu();
    });
    pop.append($el("small", "Paper color · " + design.tint));
    const names = Object.keys(tints);
    swatches(
      pop,
      Object.values(tints),
      names.indexOf(design.tint),
      (i) => {
        changePaper({ ...design, tint: names[i] });
        paperMenu();
      },
      names,
    );
  });
}
async function fileMenu() {
  const records = await library();
  openPop($("files"), "files", "Notebook", () => {
    menuAction("New notebook", newBook);
    menuAction("Open notebook or PDF…", () => $("file").click());
    menuAction("Help & About", () =>
      window.open("./guide.html", "_blank", "noopener"),
    );
    if (book) {
      menuAction("Rename notebook…", () => {
        openPop($("files"), "rename", "Notebook name", () => {
          const input = $el("input");
          input.value = title;
          input.setAttribute("aria-label", "Notebook name");
          const apply = () => {
            const name = input.value.trim();
            if (!name) return;
            title = name;
            $("name").textContent = title;
            document.title = title + " · Gridnote";
            touchSave();
            closePop();
          };
          input.onkeydown = (e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              apply();
            }
          };
          pop.append(input, button("Save name", apply));
          queueMicrotask(() => {
            input.focus();
            input.select();
          });
        });
      });
      menuAction("Download editable notebook", () => {
        const data = JSON.stringify(snapshot());
        download(
          new Blob([data], { type: "application/json" }),
          title + ".gridnote",
        );
      });
      pop.append($el("hr"));
      menuAction("Undo", () => stepHistory(undo, redo), undo.length > 0);
      menuAction("Redo", () => stepHistory(redo, undo), redo.length > 0);
      menuAction("Clear writing on this page", () => {
        finishText();
        setObjects(cleared(book.objects, currentPage()), "Clear writing");
        selection.clear();
        refresh();
      });
      menuAction("Remove typed text…", () =>
        openPop($("files"), "clear", "Remove typed text", () => {
          menuAction("This page", () => clearNotebook(true, currentPage()));
          menuAction("All pages", () => clearNotebook(true));
        }),
      );
      menuAction("Clear writing on all pages", () => clearNotebook(false));
      menuAction(
        "Delete this page",
        () => {
          finishText();
          finishGesture();
          const next = deletePage(book, currentPage());
          if (next === book) return;
          undo.push({ document: book, label: "Delete page" });
          redo = [];
          book = next;
          selection.clear();
          pdfCache.clear();
          touchSave();
          resize();
          refresh();
        },
        currentPage() < pageCount(book),
      );
      if (document.fullscreenEnabled)
        menuAction(
          document.fullscreenElement ? "Exit fullscreen" : "Enter fullscreen",
          () =>
            document.fullscreenElement
              ? document.exitFullscreen()
              : document.documentElement.requestFullscreen(),
        );
    }
    const rest = records.filter((r) => r.id !== book?.id);
    if (rest.length) {
      pop.append($el("hr"), $el("small", "Recent notebooks"));
      for (const row of rest) menuAction(row.title, () => openStored(row.id));
    }
  });
}
function selectionMenu() {
  openPop($("selection"), "selection", "Selection", () => {
    menuAction("Copy", () => {
      copySelection();
      navigator.clipboard?.writeText("Gridnote selection").catch(() => {});
    });
    menuAction(
      "Paste copy",
      () => pasteCopies(clipObjects),
      clipObjects.length > 0,
    );
    menuAction(
      "Erase selected strokes",
      () => deleteSelection(true),
      selected().some((o) => kind(o) === "ink"),
    );
    menuAction("Delete selection", () => deleteSelection());
  });
}
async function importBook(file) {
  const name = file.name.replace(/\.(pdf|gridnote)$/i, "");
  if (/\.pdf$/i.test(file.name) || file.type === "application/pdf") {
    const bytes = new Uint8Array(await file.arrayBuffer()),
      data = bytes64(bytes),
      doc = await readPDF(bytes);
    const next = { ...blank(), sourcePDF: data, sourcePages: doc.numPages };
    await doc.destroy();
    await openBook(next, name);
    touchSave();
    await flush();
  } else {
    const next = validate(JSON.parse(await file.text()));
    // Import as an independent local copy. Existing notebooks remain available in Recent.
    await openBook({ ...next, id: uid(), revision: 0 }, name);
    touchSave();
    await flush();
  }
}
let busyPDF = false;
async function pdfAction(preview) {
  if (busyPDF) return;
  finishText();
  finishGesture();
  busyPDF = true;
  const b = preview ? $("preview") : $("export"),
    old = b.textContent;
  $("preview").disabled = $("export").disabled = true;
  try {
    pdfResult = await makePDF(
      book,
      source,
      (p, n) => (b.textContent = p + "/" + n),
    );
    if (preview) {
      if (pdfPreview) await pdfPreview.destroy();
      pdfPreview = await readPDF(pdfResult.slice());
      pdfIndex = 0;
      $("pdfshare").hidden = !canSharePDF();
      $("pdfmodal").showModal();
      await updatePreview();
    } else savePDF();
  } finally {
    busyPDF = false;
    b.textContent = old;
    $("preview").disabled = $("export").disabled = false;
  }
}
$("solve").onclick = async () => {
  closePop();
  finishText();
  finishGesture();
  const b = $("solve"),
    seq = ++studySequence;
  if (studyItems.length) {
    studyItems = [];
    b.setAttribute("aria-pressed", "false");
    draw();
    return;
  }
  const page = currentPage(),
    id = book.id,
    rev = book.revision;
  b.textContent = "Scanning…";
  b.disabled = true;
  try {
    const { found, error } = await scanProblems(book, source, page);
    if (
      seq !== studySequence ||
      id !== book.id ||
      rev !== book.revision ||
      page !== currentPage()
    )
      return;
    studyItems = found;
    b.setAttribute("aria-pressed", String(!!found.length));
    draw();
    notify(
      found.length
        ? "Tap a highlighted exercise."
        : error ||
            "No supported problem found. Type an equation or add a code block in Text options.",
    );
  } catch (e) {
    notify(e.message);
  } finally {
    if (seq === studySequence) {
      b.textContent = "Solve";
      b.disabled = false;
    }
  }
};
function shareFile() {
  return new File(
    [pdfResult],
    title + (book.sourcePDF ? " - Annotated" : "") + ".pdf",
    { type: "application/pdf" },
  );
}
function canSharePDF() {
  try {
    return (
      typeof navigator.share === "function" &&
      navigator.canShare?.({ files: [shareFile()] })
    );
  } catch {
    return false;
  }
}
$("pdfshare").onclick = async () => {
  try {
    if (canSharePDF()) await navigator.share({ files: [shareFile()] });
    else savePDF();
  } catch (e) {
    if (e.name !== "AbortError")
      notify("Sharing failed. Use Save PDF to keep a copy.");
  }
};
function savePDF() {
  download(
    new Blob([pdfResult], { type: "application/pdf" }),
    title + (book.sourcePDF ? " - Annotated" : "") + ".pdf",
  );
}
async function updatePreview() {
  const token = ++previewEpoch,
    n = pdfIndex;
  const canvas = await pdfBitmap(
    pdfPreview,
    n,
    Math.min(1450, (innerWidth - 30) * Math.min(2, devicePixelRatio || 1)),
  );
  if (token !== previewEpoch) return;
  const shown = $("pdfcanvas");
  shown.width = canvas.width;
  shown.height = canvas.height;
  shown.getContext("2d").drawImage(canvas, 0, 0);
  $("pdfcount").textContent = n + 1 + " / " + pdfPreview.numPages;
  $("pdfprev").disabled = n === 0;
  $("pdfnext").disabled = n === pdfPreview.numPages - 1;
}
document.addEventListener("keydown", (e) => {
  const mod = e.metaKey || e.ctrlKey;
  if (isEntry(e.target)) {
    if (e.key === "Escape" && pop.contains(e.target)) {
      closePop();
      sheet.focus({ preventScroll: true });
      return;
    }
    if (
      e.target === editor &&
      (e.key === "Escape" || (mod && e.key === "Enter"))
    ) {
      e.preventDefault();
      finishText(e.key === "Escape");
    }
    return;
  }
  if ($("pdfmodal").open || document.querySelector("dialog[open]")) return;
  if (!book) return;
  if (mod) {
    const k = e.key.toLowerCase();
    if (k === "s") {
      e.preventDefault();
      run(flush);
    } else if (k === "z") {
      e.preventDefault();
      e.shiftKey ? stepHistory(redo, undo) : stepHistory(undo, redo);
    } else if (k === "y") {
      e.preventDefault();
      stepHistory(redo, undo);
    } else if (k === "0") {
      e.preventDefault();
      setZoom(1);
    } else if (k === "a") {
      e.preventDefault();
      pickTool("selector");
      selection = new Set(book.objects.filter(inFilter).map((o) => o.id));
      refresh();
    } else if (k === "p") {
      e.preventDefault();
      run(() => pdfAction(true));
    }
    return;
  }
  if (e.altKey) return;
  const keys = {
    KeyQ: "brush",
    KeyW: "selector",
    KeyE: "eraser",
    KeyR: "text",
  };
  if (keys[e.code]) {
    e.preventDefault();
    pickTool(keys[e.code]);
  } else if (e.code === "Space") {
    e.preventDefault();
    space = true;
  } else if (e.key === "Delete" || e.key === "Backspace") {
    e.preventDefault();
    deleteSelection();
  } else if (e.key === "Escape") {
    closePop();
    selection.clear();
    refresh();
  }
});
document.addEventListener("keyup", (e) => {
  if (e.code === "Space") {
    space = false;
    if (gesture?.type === "pan") finishGesture();
  }
});
function onBackground() {
  if (!book) return;
  finishGesture();
  endTransient();
  recordView(true);
  flush().catch(() => {});
  refresh();
}
window.addEventListener("blur", onBackground);
window.addEventListener("pagehide", onBackground);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) onBackground();
});
document.addEventListener(
  "pointerdown",
  (e) => {
    if (
      !pop.hidden &&
      !pop.contains(e.target) &&
      !e.target.closest("button,select")
    )
      closePop();
  },
  true,
);
function clearNotebook(typedOnly, page = null) {
  finishText();
  finishGesture();
  const next = book.objects.flatMap((o) => {
    if (
      o.table ||
      o.codeStyle != null ||
      o.instrument === "shape" ||
      kind(o) === "image" ||
      (typedOnly && kind(o) === "ink")
    )
      return [o];
    return page == null ? [] : cleared([o], page);
  });
  setObjects(next, typedOnly ? "Remove typed text" : "Clear writing");
  selection.clear();
  refresh();
}
sheet.ondblclick = (e) => {
  if (tool !== "selector") return;
  const p = point(e),
    o = [...book.objects]
      .reverse()
      .find((o) => kind(o) === "text" && contains(o.frame, p));
  if (o?.table) {
    const i = o.table.cells.findIndex((_, i) => contains(cellFrame(o, i), p));
    if (i >= 0) startCell(o, i);
  } else if (o) startText(p, o);
};
$("code-toggle").onclick = () => {
  const o = selected()[0];
  if (o?.codeStyle != null)
    setObjects(
      book.objects.map((q) =>
        q.id === o.id ? { ...q, codeStyle: !q.codeStyle } : q,
      ),
      "Toggle syntax colors",
    );
};
for (const [id, [label, key, glyph]] of Object.entries(toolNames)) {
  const b = button("", () => {
    pickTool(id);
    toolOptions(b, id);
  });
  b.id = "tool-" + id;
  b.title = label + " (" + key + ") · options";
  b.setAttribute("aria-label", label);
  const mark = $el("span", glyph);
  mark.className = "glyph";
  const name = $el("span", label);
  name.className = "tool-name";
  b.append(mark, name);
  if (key) b.append($el("kbd", key));
  $("toolset").append(b);
}
for (const [i, c] of inks.entries()) {
  const b = button(
    "",
    () => {
      setting(
        tool === "marker" ? "markerInk" : tool === "text" ? "textInk" : "ink",
        i,
      );
      refresh();
    },
    "swatch",
  );
  b.style.setProperty("--swatch", rgb(c));
  b.title = inkNames[i];
  b.setAttribute("aria-label", inkNames[i]);
  $("inks").append(b);
}
$("palette").onclick = () => {
  if (innerWidth <= 650) openPop($("palette"), "ink", "Ink color", penColors);
  else {
    setting("palette", !settings().palette);
    refresh();
  }
};
$("settings").onclick = settingsMenu;
$("paper").onclick = paperMenu;
$("selection").onclick = selectionMenu;
$("new").onclick = () => run(newBook);
$("open").onclick = () => $("file").click();
$("files").onclick = () => run(fileMenu);
$("file").onchange = () =>
  run(async () => {
    const f = $("file").files[0];
    $("file").value = "";
    if (f) await importBook(f);
  });
$("imagefile").onchange = () =>
  run(async () => {
    const fs = [...$("imagefile").files];
    $("imagefile").value = "";
    for (const f of fs) await insertImage(f);
  });
$("addimage").onclick = () => imageMenu();
$("undo").onpointerdown = $("redo").onpointerdown = (e) => e.preventDefault();
$("undo").onclick = () => {
  if (editing) {
    editor.focus();
    document.execCommand("undo");
  } else stepHistory(undo, redo);
};
$("redo").onclick = () => {
  if (editing) {
    editor.focus();
    document.execCommand("redo");
  } else stepHistory(redo, undo);
};
$("saved").onclick = () => {
  if (error) notify(error);
  run(flush);
};
$("preview").onclick = () => run(() => pdfAction(true));
$("export").onclick = () => run(() => pdfAction(false));
$("fit").onclick = () => setZoom(1);
$("zoomout").onclick = () => setZoom(zoom / 1.22);
$("zoomin").onclick = () => setZoom(zoom * 1.22);
$("pdfclose").onclick = () => $("pdfmodal").close();
$("pdfsave").onclick = savePDF;
$("pdfprev").onclick = () => {
  if (pdfIndex > 0) {
    pdfIndex--;
    run(updatePreview);
  }
};
$("pdfnext").onclick = () => {
  if (pdfIndex + 1 < pdfPreview.numPages) {
    pdfIndex++;
    run(updatePreview);
  }
};
const detectedLabel = $("detected-device");
detectedLabel.hidden = mobileSurface;
detectedLabel.textContent = deviceLabel();
function refreshDetection() {
  detectHardware().then(() => {
    detectedLabel.textContent = deviceLabel();
    if (book) refresh();
  });
}
refreshDetection();
window.addEventListener("focus", refreshDetection);
navigator.hid?.addEventListener("connect", refreshDetection);
navigator.hid?.addEventListener("disconnect", refreshDetection);
function imageMenu() {
  openPop($("addimage"), "image", "Add image", () => {
    if (cameraSupported())
      menuAction("Take photo…", async () => {
        const page = currentPage(),
          photo = await capturePhoto();
        if (photo) await insertImage(photo, page);
      });
    menuAction("Choose an image…", () => $("imagefile").click());
    if (navigator.clipboard?.read)
      menuAction("Paste screenshot", async () => {
        const items = await navigator.clipboard.read();
        for (const item of items) {
          const type = item.types.find((t) => t.startsWith("image/"));
          if (type) {
            await insertImage(await item.getType(type));
            return;
          }
        }
        throw Error("Copy an image first.");
      });
  });
}
run(async () => {
  const last = await loadState("last");
  if (last) {
    await openStored(last);
    return;
  }
  const recents = await library();
  for (const item of recents.slice(0, 5))
    $("recents").append(
      button(item.title, () => run(() => openStored(item.id))),
    );
}).finally(() => {
  $("new").disabled = false;
  $("open").disabled = false;
});
if ("serviceWorker" in navigator)
  navigator.serviceWorker
    .register("./sw.js")
    .catch((e) => notify("Offline setup failed: " + e.message));
