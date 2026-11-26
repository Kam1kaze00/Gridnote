import { imageSize, initialImageSize } from "./image-size.mjs";
import { pageSidebar } from "./pages.mjs";
import { arrangedPages, sourceIndex } from "./engine.mjs";
import { erasePart } from "./eraser.mjs";
import { scanProblems, studyContent } from "./study.mjs";
import {
  markers,
  markerNames,
  tableGrid,
  textFormat, cellKey, fontFor, textLines,
  cellFrame,
  shapeObject,
  align,
  resizeGuides,
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
  groupRect,
  contains,
  overlaps,
  makeInk,
  fittedInk,
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
  lastNotebookInfo,
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
  brushMotion,
  sampledRadius,
  restore,
  settings,
  setting,
  deviceHelp,
} from "./devices.mjs";
import {
  grainReady,
  inkFootprint,
  paintFootprint,
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
  brush: ["Writer", "Q"],
  selector: ["Selector", "W"],
  eraser: ["Eraser", "E"],
  text: ["Text", "R"],
  marker: ["Highlighter", ""],
  shapes: ["Shapes", ""],
  table: ["Table", ""],
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
let formatCell = null;
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
  previewFile = null,
  pdfPreview = null,
  pdfIndex = 0,
  previewEpoch = 0,
  popupKind = "",
  popupAnchor,
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
let inkBackdrop = null;
let lastScan = null, highlightedPage = null;
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
const bundledIPad = navigator.userAgent.includes("Gridnote-iPad/");
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
    const value = editor.value;
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
  lastScan = null;
  clearStudyHighlights();
  studySequence++;
  $("solve").textContent = "Solve";
  $("solve").disabled = false;
  const prior = book;
  book = { ...book, revision: book.revision + 1 };
  // Autosaving a live stroke increments its revision without changing the committed page.
  if (inkBackdrop?.book === prior) inkBackdrop.book = book;
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
  if (!book || restoring || document.body.classList.contains("launching")) return;
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
  clearStudyHighlights();
  $("solve").disabled = false;
  $("solve").textContent = "Solve";
  studySequence++;
  inkBackdrop = null;
  lastScan = null;
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
  document.body.classList.remove("launching");
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
  await saveState("last", id);
  if (loaded.recovered) {
    touchSave();
    notify("Restored a recent recovery copy.");
  }
}
async function newBook() {
  const notebook = blank();
  await openBook(notebook, "Untitled Notebook");
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
function refreshPageControls() {
  const page = currentPage();
  if (highlightedPage !== null && highlightedPage !== page) {
    if (popupKind === "study" || popupKind === "single-study") closePop();
    clearStudyHighlights();
  }
  updateSidebar(book, source, page);
  const label = "Page " + (page + 1);
  if ($("page").textContent !== label) $("page").textContent = label;
  const ruling = sourceIndex(book, page) != null ? "PDF" : paper(book, page).ruling;
  const paperLabel = "A4 · " + ruling + " ⌄";
  if ($("paper").textContent !== paperLabel) $("paper").textContent = paperLabel;
}
function refresh() {
  if (!book) return;
  const prefs = settings();
  for (const id of Object.keys(toolNames)) {
    const button = $("tool-" + id);
    button.setAttribute("aria-pressed", String(id === effective()));
    updateToolIcon(id, button, prefs);
  }
  sheet.className = lower || gesture?.type === "pan" ? "pan" : effective();
  $("undo").disabled = !undo.length && !editing;
  $("redo").disabled = !redo.length && !editing;
  refreshPageControls();
  $("selection").hidden = tool !== "selector" || !selection.size;
  $("selection").textContent = selection.size + " selected ⌄";
  $("zoom").textContent = Math.round(zoom * 100) + "%";
  $("zoomout").disabled = zoom <= 1.001;
  $("zoomin").disabled = zoom >= 3.999;
  $("inks").hidden = !prefs.palette;
  $("palette").setAttribute("aria-pressed", String(prefs.palette));
  const textInk = tool === "text" ? inks.findIndex(c => rgb(c) === rgb(currentFormat(false).color)) : prefs.textInk;
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
              ? textInk
              : prefs.ink),
      ),
    );
  }
  updateStatus();
  draw();
}
function resize() {
  if (!book || document.body.classList.contains("launching")) return;
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
  if (inkBackdrop) inkBackdrop.book = null;
  draw();
}
function inkNib(prefs, seed = 71) {
  const nib = {tip:prefs.nib, width:prefs.width, textured:true};
  return prefs.nib === "Brush" ? {...nib, finish:prefs.brushFinish, seed} : nib;
}
function paintLiveInk(g) {
  // Freeze completed portions of the preview. The full-resolution stroke is
  // fitted once at commit, using all original pressure and timing samples.
  function section(start, end) {
    const raw = g.raw.slice(start, end),
      times = g.times.slice(start, end);
    const o = makeInk(fittedInk(raw, g.prefs, times, start === 0, false, g.marker), g.color, g.id);
    o.ballpointWidth = g.ballpointWidth;
    o.inkNib = g.inkNib;
    return inkFootprint(o);
  }
  function add(target, part) {
    target.body.addPath(part.body);
    if (part.core) { target.core ??= new Path2D(); target.core.addPath(part.core); }
  }
  while (g.raw.length - g.previewStart > 100) {
    const end = g.previewStart + 96;
    add(g.prefix, section(g.previewStart, end + 1));
    g.previewStart = end;
  }
  const outline = {nib:g.inkNib, body: new Path2D(g.prefix.body), core: g.prefix.core && new Path2D(g.prefix.core)};
  add(outline, section(g.previewStart, g.raw.length));
  ctx.save();
  if (g.marker) {
    ctx.globalAlpha = g.prefs.opacity;
    ctx.globalCompositeOperation = "multiply";
  }
  paintFootprint(ctx, outline, g.color, g.ballpointWidth ? g.prefs.penFlow : 1);
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
  const reusable = !editing && ["brush", "marker"].includes(effective());
  if (!reusable) inkBackdrop = null;
  if (inkBackdrop?.book === book && inkBackdrop.viewKey === viewKey) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(inkBackdrop.surface, 0, 0);
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
              if (doc === source && pdfCache.get(n) === hold) {
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
    if (live && reusable) {
      const surface = inkBackdrop?.surface ?? document.createElement("canvas");
      if (surface.width !== sheet.width) surface.width = sheet.width;
      if (surface.height !== sheet.height) surface.height = sheet.height;
      const base = surface.getContext("2d");
      base.setTransform(1, 0, 0, 1, 0, 0);
      base.drawImage(sheet, 0, 0);
      base.setTransform(s, 0, 0, s, -left * s, -top * s);
      inkBackdrop = { surface, book, viewKey };
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
  if (gesture?.measure) {
    const { point, text } = gesture.measure;
    ctx.save();
    ctx.font = 11 / scale + "px system-ui";
    const w = ctx.measureText(text).width + 12 / scale,
      h = 21 / scale;
    const x = clamp(
      point[0] + 10 / scale,
      left + 2 / scale,
      left + view.clientWidth / scale - w - 2 / scale,
    );
    const y = clamp(
      point[1] + 12 / scale,
      top + 2 / scale,
      top + view.clientHeight / scale - h - 2 / scale,
    );
    ctx.fillStyle = "#263536";
    ctx.fillRect(x, y, w, h);
    ctx.fillStyle = "#fff";
    ctx.fillText(text, x + 6 / scale, y + 14 / scale);
    ctx.restore();
  }
  const code =
      tool === "selector" ? editing?.object || (selection.size === 1 ? selected()[0] : null) : null,
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
    if (popupAnchor && !pop.hidden) positionPop(popupAnchor);
  }
}).observe(view);
new ResizeObserver(() => {
  if (popupAnchor && !pop.hidden) positionPop(popupAnchor);
}).observe(pop);
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
    refreshPageControls();
    draw();
    recordView();
  },
  { passive: true },
);
function pickTool(id) {
  erasingContact = false;
  clearStudyHighlights();
  studySequence++;
  $("solve").disabled = false;
  $("solve").textContent = "Solve";
  const idToFormat = editing?.object.id;
  const cell = editing?.cell;
  finishText();
  if (id === "text" && idToFormat && book.objects.some(o => o.id === idToFormat)) selection = new Set([idToFormat]);
  formatCell = id === "text" && cell != null ? {id:idToFormat, cell} : null;
  finishGesture();
  armed = false;
  tool = id;
  closePop();
  sheet.focus({ preventScroll: true });
  refresh();
  recordView();
}
function append(e, p, isUp = false) {
  const g = gesture, last = g.raw.at(-1), now = e.timeStamp * 0.001;
  const distance = last ? dist(last.position, p) : 0;
  let crossTilt = 0;
  if (g.stylus && (g.prefs.nib === "Brush" || g.prefs.nib === "Pencil") && distance > 0.01) {
    crossTilt = ((e.tiltX || 0) * (p[1] - last.position[1]) -
      (e.tiltY || 0) * (p[0] - last.position[0])) / (90 * distance);
  }
  const radius = g.marker ? g.prefs.markerWidth / 2 : sampledRadius(g.prefs,
    g.stylus && !isUp ? e.pressure : null, last?.radius, distance,
    now - (g.times.at(-1) ?? now), isUp, g.stylus, crossTilt);
  p = [
    clamp(p[0], radius, W - radius),
    clamp(p[1], radius, pages * H - radius),
  ];
  const moved = !last || dist(last.position, p) >= 0.12;
  if (moved) g.lastMotion = now;
  if (isUp) {
    g.lifted = now - g.lastMotion <= 0.09;
    liveInk = null;
  }
  if (last && !moved) {
    if (!isUp && Math.abs(radius - last.radius) > 0.005) {
      last.radius = g.raw.length === 1 ? Math.max(last.radius, radius) : radius;
      g.times[g.times.length - 1] = e.timeStamp * 0.001;
      liveInk = null;
    }
    return;
  }
  const point = {position: p, radius};
  if (g.inkNib?.tip === "Brush") {
    Object.assign(point, brushMotion(last, last ? dist(last.position, p) : 0,
      now - (g.times.at(-1) ?? now), g.inkNib.width));
  }
  g.raw.push(point);
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
      fittedInk(gesture.raw, gesture.prefs, gesture.times, true, gesture.lifted, gesture.marker),
      gesture.color,
      gesture.id,
    );
    if (gesture.inkNib) liveInk.inkNib = gesture.inkNib;
    if (gesture.ballpointWidth) {
      liveInk.ballpointWidth = gesture.ballpointWidth;
      if (gesture.prefs.penFlow < 1) liveInk.opacity = gesture.prefs.penFlow;
    }
    if (gesture.marker) {
      liveInk.instrument = "marker";
      liveInk.opacity = gesture.prefs.opacity;
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
    const stylus = e.pointerType === "pen" && devices[device][1];
    const ballpointWidth = mode === "brush" && prefs.nib === "Pen"
      ? prefs.width : null;
    const id = uid();
    gesture = {
      type: "ink", stylus, ballpointWidth, inkNib: mode === "brush" ? inkNib(prefs, parseInt(id.slice(0, 2), 16)) : undefined,
      prefs,
      previewStart: 0,
      prefix: {body: new Path2D(), core: ballpointWidth ? new Path2D() : null},
      marker: mode === "marker",
      id,
      raw: [],
      times: [],
      color: mode === "marker" ? markers[prefs.markerInk] : color(),
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
        const target = selected()[0];
        gesture = { type: "move", start: p, box, before: book.objects,
          edit: selection.size === 1 && kind(target) === "text" && contains(target.frame, p) ? target : null };
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
          edit: kind(hitObject) === "text" ? hitObject : null,
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
      additive: e.shiftKey,
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
    g.preview = newTable(f, s.rows, s.columns, g.id ??= uid());
  }
  if (g.type === "ink") append(e, p);
  if (g.type === "erase") erase(p);
  if (g.type === "region") {
    if (g.mode === "Rectangle") g.points = [g.start, p];
    else if (dist(g.points.at(-1), p) > 1 / scale) g.points.push(p);
  }
  if (g.type === "move" || g.type === "resize") {
    if (g.edit) {
      if (dist(g.start, p) * scale <= 4) return;
      g.edit = null;
    }
    const [[x, y], [w, h]] = g.box;
    let dx = 0,
      dy = 0,
      k = 1,
      anchor = [0, 0];
    if (settings().guides && !g.targets) {
      const visible = [
        [view.scrollLeft / scale, view.scrollTop / scale],
        [view.clientWidth / scale, view.clientHeight / scale],
      ];
      g.targets = g.before
        .filter((o) => !selection.has(o.id) && overlaps(o.frame, visible))
        .map((o) => o.frame);
    }
    function dimensions(box) {
      if (!settings().guides) return;
      const { guides, matches } = resizeGuides(
        box,
        g.targets,
        4 / scale,
        g.anchor,
      );
      g.guides = guides;
      g.measure = {
        point: p,
        text:
          box[1].map((n) => ((n * 25.4) / 72).toFixed(1)).join(" × ") +
          " mm" +
          (matches.length ? " · " + matches.join("+") : ""),
      };
    }
    if (g.type === "move") {
      dx = clamp(
        p[0] - g.start[0],
        Math.min(0, W - w) - x,
        Math.max(0, W - w) - x,
      );
      dy = Math.max(-y, p[1] - g.start[1]);
      g.guides = [];
      if (settings().guides && (Math.abs(dx) + Math.abs(dy)) * scale > 2) {
        const a = align(
          [
            [x + dx, y + dy],
            [w, h],
          ],
          g.targets,
          4 / scale,
        );
        dx = clamp(
          dx + a.adjust[0],
          Math.min(0, W - w) - x,
          Math.max(0, W - w) - x,
        );
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
        dimensions(book.objects.find((o) => o.id === t.id).frame);
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
        Math.max(1, max),
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
    if (g.type === "resize")
      dimensions([
        [anchor[0] + (x - anchor[0]) * k, anchor[1] + (y - anchor[1]) * k],
        [w * k, h * k],
      ]);
  }
  draw();
}
function editTappedObject(object, point) {
  if (object.table) {
    const i = object.table.cells.findIndex((_, i) =>
      contains(cellFrame(object, i), point),
    );
    if (i >= 0) startCell(object, i);
  } else startText(point, object);
  if (editing) placeCaretAtTap(point);
}
function finishGesture(p) {
  const g = gesture;
  if (!g) return;
  if (p && g.edit && dist(g.start, p) * scale <= 4) {
    gesture = null;
    editTappedObject(g.edit, p);
    return;
  }
  let next, before;
  const cachedPage = inkBackdrop?.book === book ? inkBackdrop : null;
  let stroke;
  if (g.type === "ink" && g.raw.length) {
    stroke = currentInk();
    next = [...book.objects, stroke];
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
    if (p && isTap && !g.erase && !g.additive && hits.length === 1 && kind(hits[0]) === "text") {
      gesture = null;
      editTappedObject(hits[0], p);
      return;
    }
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
        ? (g.marker ? "Highlight" : "Handwriting")
        : g.type === "region" || g.type === "erase"
          ? "Erase"
          : "Transform",
      before || book.objects,
    );
  else refresh();
  // Composite the final pressure outline just once, including multiply-blended highlighter.
  // The raster holds paper and committed objects only. Guides and live ink stay on the sheet.
  if (stroke && cachedPage && inkBackdrop === cachedPage) {
    paintObject(cachedPage.surface.getContext("2d"), stroke);
    cachedPage.book = book;
  }
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
  const p = point(e);
  const selectTouch = effective() === "selector" && (settings().select !== "Tap" ||
    (selection.size && contains(groupRect(selected()), p, 12 / scale)) ||
    book.objects.some(o => inFilter(o) && hit(o, p, 3.5 / scale)));
  if (touches.size >= 2 || (!fingerWrites() && !selectTouch)) {
    if (gesture) {
      if (gesture.before && gesture.changed) book = {...book, objects:gesture.before};
      gesture = null;
      liveInk = null;
      touchSave();
      draw();
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
  if (touches.size >= 2) refresh();
  return true;
}
document.addEventListener("pointerover", (e) => {
  if (e.pointerType !== "pen") return;
  const previous = device;
  observePointer(e);
  if (book && previous !== device) {
    refresh();
    if (popupKind === "tool" && popupAnchor) toolOptions(popupAnchor, tool);
  }
});
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
          effective() === "table")
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
    textTraits: base ? base.textTraits : settings().textTraits,
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
      o.codeStyle != null ? "ui-monospace, Menlo, monospace" : "-apple-system, BlinkMacSystemFont, Arial, sans-serif",
    fontWeight: o.textTraits & 1 ? "bold" : editing.parent?.table.header && editing.cell < editing.parent.table.columns ? "600" : "normal",
    fontStyle: o.textTraits & 2 ? "italic" : "normal",
    textDecoration: o.textTraits & 4 ? "underline" : "none",
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
function updateEditActions() {
  const active = mobileSurface && !!editing;
  const cell = editing?.parent?.table;
  $("edit-actions").hidden = !active;
  document.body.classList.toggle("editing-touch", active);
  if (!active) {
    document.body.style.removeProperty("--keyboard-inset");
    return;
  }
  $("previous-cell").hidden = $("next-cell").hidden = !cell;
  $("previous-cell").disabled = !cell || editing.cell === 0;
  $("next-cell").disabled = !cell || editing.cell + 1 === cell.cells.length;
  $("edit-position").textContent = cell
    ? "Row " + (1 + Math.floor(editing.cell / cell.columns)) + " · Column " + (1 + editing.cell % cell.columns)
    : (editing.object.codeStyle != null ? "Code" : "Text");
  keepEditorVisible();
}
function keepEditorVisible() {
  if (!mobileSurface || !editing) return;
  const visible = window.visualViewport;
  if (visible && Math.abs(visible.scale - 1) > 0.02) return;
  const inset = visible ? Math.max(0, document.documentElement.clientHeight - visible.height - visible.offsetTop) : 0;
  document.body.style.setProperty("--keyboard-inset", Math.round(inset) + "px");
  if (!restoring) {
    const field = editor.getBoundingClientRect(), area = view.getBoundingClientRect();
    // Long notes can exceed the viewport. Let the text field manage its own caret in that case.
    if (field.height + 12 < area.height) {
      if (field.bottom > area.bottom - 6) view.scrollTop += field.bottom - area.bottom + 6;
      else if (field.top < area.top + 6) view.scrollTop += field.top - area.top - 6;
    }
  }
}
window.visualViewport?.addEventListener("resize", keepEditorVisible);
window.visualViewport?.addEventListener("scroll", keepEditorVisible);

function advanceCell(delta) {
  if (!editing?.parent) return;
  const id = editing.parent.id, index = editing.cell + delta;
  finishText();
  const o = book.objects.find(item => item.id === id);
  if (o && index >= 0 && index < o.table.cells.length) startCell(o, index);
}
for (const [id, delta] of [["previous-cell", -1], ["next-cell", 1]]) {
  $(id).onmousedown = e => e.preventDefault();
  $(id).onclick = () => advanceCell(delta);
}
$("edit-done").onmousedown = e => e.preventDefault();
$("edit-done").onclick = () => { finishText(); refresh(); };
function startText(p, old, caret, length = 0) {
  const prefs = settings(),
    at = [clamp(p[0], 4, W - 94), Math.max(0, p[1])],
    o = old || textObject(null, "", at, prefs.textSize, inks[prefs.textInk]);
  if (!old && prefs.code) o.codeStyle = true;
  editing = { object: o, existing: !!old };
  selection = old && tool === "selector" ? new Set([old.id]) : new Set();
  editor.value = o.content.text._0;
  editor.hidden = false;
  editor.dir = "auto";
  placeEditor();
  editor.focus({ preventScroll: true });
  editor.setSelectionRange(
    caret ?? editor.value.length,
    (caret ?? editor.value.length) + length,
  );
  updateEditActions();
  recordView();
  draw();
}
// Hit-test the browser's own wrapped and bidi text layout at the original tap.
function placeCaretAtTap(p) {
  if (!editor.value) return;
  const rect = editor.getBoundingClientRect(),
    style = getComputedStyle(editor);
  const mirror = document.createElement("div");
  Object.assign(mirror.style, {
    position: "fixed",
    left: rect.left + "px",
    top: rect.top + "px",
    width: rect.width + "px",
    height: rect.height + "px",
    zIndex: "99",
    overflow: "hidden",
    whiteSpace: "pre-wrap",
    overflowWrap: "break-word",
    font: style.font,
    lineHeight: style.lineHeight,
    textAlign: style.textAlign,
    direction: style.direction,
    tabSize: style.tabSize,
  });
  mirror.textContent = editor.value;
  document.body.append(mirror);
  try {
    const [x, y] = editing.object.frame[0];
    const clientX = rect.left + (p[0] - x) * scale,
      clientY = rect.top + (p[1] - y) * scale;
    const caret = document.caretPositionFromPoint?.(clientX, clientY);
    const range = caret
      ? null
      : document.caretRangeFromPoint?.(clientX, clientY);
    const node = caret?.offsetNode ?? range?.startContainer;
    const offset = caret?.offset ?? range?.startOffset;
    if (node === mirror.firstChild) editor.setSelectionRange(offset, offset);
  } finally {
    mirror.remove();
  }
}
function startCell(o, i, caret, length = 0) {
  const frame = cellFrame(o, i),
    style = textFormat(o, i),
    proxy = {
      id: o.id,
      frame: [
        [frame[0][0] + 3, frame[0][1] + 2],
        [Math.max(1, frame[1][0] - 6), Math.max(1, frame[1][1] - 4)],
      ],
      alignment: style.alignment,
      textTraits: style.traits,
      content: {
        text: {
          ...o.content.text,
          _0: o.table.cells[i],
          _1: style.color,
          _2: Math.min(style.size, frame[1][1] * 0.64),
        },
      },
    };
  startText(frame[0], proxy, caret, length);
  editing.parent = o;
  editing.cell = i;
  placeEditor();
  updateEditActions();
  recordView();
}
function finishText(cancel = false) {
  if (!editing) return;
  const e = editing,
    value = editor.value;
  const next = snapshot().objects;
  editing = null;
  updateEditActions();
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
async function insertImage(file, onPage = null, dropPoint = null) {
  const notebookID = book.id;
  const url = URL.createObjectURL(file),
    img = new Image();
  try {
    img.src = url;
    await img.decode();
    const bytes = new Uint8Array(await file.arrayBuffer());
    const natural = imageSize(
      bytes,
      img.naturalWidth,
      img.naturalHeight,
    );
    let data;
    if (
      bytes[0] === 137 &&
      bytes[1] === 80 &&
      bytes[2] === 78 &&
      bytes[3] === 71
    )
      data = bytes64(bytes);
    else {
      const canvas = document.createElement("canvas");
      canvas.width = img.naturalWidth;
      canvas.height = img.naturalHeight;
      canvas.getContext("2d").drawImage(img, 0, 0);
      const blob = await new Promise((resolve) =>
        canvas.toBlob(resolve, "image/png"),
      );
      if (!blob)
        throw Error("The image is too large to decode on this device.");
      data = bytes64(new Uint8Array(await blob.arrayBuffer()));
    }
    if (book?.id !== notebookID) return;
    const object = { id: uid(), frame: [[0, 0], natural], content: { image: { _0: data } } };
    const page = onPage ?? (dropPoint ? Math.max(0, Math.floor(dropPoint[1] / H)) : currentPage());
    placeImage(object, dropPoint ?? insertion(), page, onPage !== null);
  } finally {
    URL.revokeObjectURL(url);
  }
}
function placeImage(object, preferred, page, camera = false) {
  const visibleWidth = view.clientWidth / scale || W, visibleHeight = view.clientHeight / scale || H;
  const [width, height] = initialImageSize(object.frame[1], visibleWidth, visibleHeight);
  const top = page * H, maxY = top + H - G - height;
  let [x, y] = preferred;
  if (camera) {
    const last = book.objects
      .filter(o => o.frame[0][1] >= top && o.frame[0][1] < top + H)
      .reduce((end, o) => Math.max(end, o.frame[0][1] + o.frame[1][1]), top + 2 * G);
    x = view.scrollLeft / scale + (visibleWidth - width) / 2;
    y = Math.max(view.scrollTop / scale + 2 * G, last + G <= maxY ? last + G : top + 2 * G);
  }
  x = clamp(x, G, W - G - width);
  y = clamp(y, top + G, maxY);
  const [anchor, size] = object.frame;
  const placed = transform(object, anchor, width / size[0], x - anchor[0], y - anchor[1]);
  replaceObjects([placed], "Insert image");
  if (y < view.scrollTop / scale || y + height > view.scrollTop / scale + visibleHeight)
    view.scrollTop = Math.max(0, (y - G) * scale);
  if (x < view.scrollLeft / scale || x + width > view.scrollLeft / scale + visibleWidth)
    view.scrollLeft = Math.max(0, (x - G) * scale);
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
    [[x, y], [w]] = box,
    p = insertion(),
    visible = [
      [view.scrollLeft / scale, view.scrollTop / scale],
      [view.clientWidth / scale, view.clientHeight / scale],
    ];
  const nearPage = overlaps(box, visible);
  if (items.length === 1 && kind(items[0]) === "image") {
    placeImage({ ...items[0], id: uid() }, nearPage ? [x + 12, y + 12] : p, currentPage());
    return;
  }
  const dx = clamp(nearPage ? x + 12 : p[0], 0, Math.max(0, W - w)) - x,
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
  if (book && !document.body.classList.contains("launching") && !isEntry(e.target) && copySelection(e)) deleteSelection();
});
document.addEventListener("paste", (e) => {
  if (!book || document.body.classList.contains("launching") || isEntry(e.target)) return;
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
  const at = point(e), files = Array.from(e.dataTransfer.files);
  run(async () => {
    for (const file of files) {
      if (file.type.startsWith("image/")) await insertImage(file, null, at);
      else await importBook(file);
    }
  });
};
function clearStudyHighlights() {
  studyItems = [];
  highlightedPage = null;
  $("solve").setAttribute("aria-pressed", "false");
}
function closePop() {
  pop.dispatchEvent(new Event("panelclose"));
  if (popupKind === "single-study") {
    clearStudyHighlights();
    draw();
  }
  pop.hidden = true;
  popupKind = "";
  popupAnchor = null;
}
function openPop(anchor, type, heading, build) {
  pop.dispatchEvent(new Event("panelclose"));
  pop.oninput = null;
  pop.replaceChildren();
  if (heading) pop.append($el("h2", heading));
  popupKind = type;
  popupAnchor = anchor;
  build();
  pop.hidden = false;
  positionPop(anchor);
}
function positionPop(anchor) {
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
  const row = $el("div");
  row.className = "choices";
  if (label === "Brush finish") {
    row.classList.add("brush-finish");
    row.setAttribute("role", "group");
    row.setAttribute("aria-label", label);
    row.append($el("small", "Finish"));
  } else if (label) pop.append($el("small", label));
  if (label === "Writing tip") row.classList.add("writing-tips");
  items.forEach((item) => {
    const b = button(item, () => {
      select(item);
      for (const el of row.querySelectorAll("button")) {
        el.classList.toggle("active", el === b);
        el.setAttribute("aria-pressed", String(el === b));
      }
      refresh();
    });
    b.classList.toggle("active", value === item);
    b.setAttribute("aria-pressed", String(value === item));
    row.append(b);
  });
  pop.append(row);
}
function slider(label, key, min, max, step, format, initial = settings()[key], change = v => setting(key, v)) {
  const row = $el("label");
  row.className = "field";
  const output = $el("output", format(initial)),
    input = $el("input");
  input.type = "range";
  input.min = min;
  input.max = max;
  input.step = step;
  input.value = initial;
  input.setAttribute("aria-label", label);
  input.oninput = () => {
    change(Number(input.value));
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
function penColors(onChange) {
  const prefs = settings(),
    marker = tool === "marker",
    key = marker ? "markerInk" : tool === "text" ? "textInk" : "ink";
  swatches(
    pop,
    (marker ? markers : inks).map(rgb),
    key === "textInk" ? inks.findIndex(c => rgb(c) === rgb(currentFormat(false).color)) : prefs[key],
    (i) => {
      if (key === "textInk") {
        if (editing) pickTool("text");
        changeFormat(false, "color", inks[i]);
      } else setting(key, i);
      refresh();
      onChange?.();
    },
    marker ? markerNames : inkNames,
  );
}
function checkOption(label, checked, change) {
  const l = $el("label"),
    c = $el("input");
  c.type = "checkbox";
  c.checked = checked;
  c.onchange = () => { change(c.checked); refresh(); };
  l.append(c, document.createTextNode(label));
  pop.append(l);
  return c;
}
function defaultFormat(table) {
  const p = settings();
  if (table)
    return (
      p.tableText || { size: 11, color: inks[0], alignment: "Auto", traits: 0 }
    );
  return {
    size: p.textSize,
    color: inks[p.textInk],
    alignment: p.alignment,
    traits: p.textTraits,
  };
}
function newTable(
  frame,
  rows,
  columns,
  id = uid(),
  header = settings().header,
) {
  const f = defaultFormat(true);
  return {
    id,
    frame,
    alignment: f.alignment,
    textTraits: f.traits,
    table: tableGrid(rows, columns, header),
    content: { text: { _0: "", _1: f.color, _2: f.size } },
  };
}
function formatTarget(table) {
  const o = selection.size === 1 ? selected()[0] : null;
  if (!o?.content.text) return null;
  if (table) return o.table ? o : null;
  return !o.table || formatCell?.id === o.id ? o : null;
}
function currentFormat(table) {
  if (!table && editing) return textFormat(editing.object);
  const o = formatTarget(table);
  return o
    ? textFormat(o, !table && o.table ? formatCell.cell : null)
    : defaultFormat(table);
}
function changeFormat(table, key, value) {
  const o = formatTarget(table);
  if (!o) {
    if (table) setting("tableText", { ...defaultFormat(true), [key]: value });
    else if (key === "color")
      setting(
        "textInk",
        inks.findIndex((c) => rgb(c) === rgb(value)),
      );
    else
      setting(
        { size: "textSize", alignment: "alignment", traits: "textTraits" }[key],
        value,
      );
    return;
  }
  const f = { ...currentFormat(table), [key]: value };
  let next = { ...o };
  if (!table && o.table) {
    next.table = {
      ...o.table,
      formats: { ...o.table.formats, [cellKey(o.table, formatCell.cell)]: f },
    };
  } else {
    next.content = { text: { ...o.content.text, _1: f.color, _2: f.size } };
    next.alignment = f.alignment;
    next.textTraits = f.traits;
    if (o.table?.formats)
      next.table = {
        ...o.table,
        formats: Object.fromEntries(
          Object.entries(o.table.formats).map(([k, v]) => [
            k,
            { ...v, [key]: value },
          ]),
        ),
      };
    if (!o.table && !o.layoutFrame) {
      const ctx = sheet.getContext("2d");
      ctx.save();
      ctx.font = fontFor(f);
      const lines = textLines(ctx, o.content.text._0, o.frame[1][0]);
      ctx.restore();
      next.frame = [
        o.frame[0],
        [o.frame[1][0], Math.max(24, lines.length * f.size * 1.2 + 8)],
      ];
      if (o.codeStyle != null)
        next = textObject(next, o.content.text._0, o.frame[0], f.size, f.color);
    }
  }
  setObjects(
    book.objects.map((item) => (item.id === o.id ? next : item)),
    "Format text",
  );
}
function formatOptions(table) {
  const f = currentFormat(table),
    row = $el("div");
  row.className = "type-controls";
  const label = $el(
    "small",
    table
      ? "Table text"
      : formatTarget(false)?.table
        ? "Cell text"
        : "Text style",
  );
  row.append(label);
  const ink = $el("select");
  ink.setAttribute("aria-label", "Text color");
  inkNames.forEach((name, i) => ink.add(new Option(name, i)));
  ink.value = inks.findIndex((c) => rgb(c) === rgb(f.color));
  ink.onchange = () => {
    changeFormat(table, "color", inks[Number(ink.value)]);
    refresh();
  };
  row.append(ink);
  if (table) {
    const sizes = $el("select");
    sizes.setAttribute("aria-label", "Table type size");
    for (const pt of [
      ...new Set([8, 10, 11, 12, 14, 16, 18, 24, 30, 36, f.size]),
    ].sort((a, b) => a - b))
      sizes.add(new Option(pt + " pt", pt));
    sizes.value = f.size;
    sizes.onchange = () => changeFormat(true, "size", Number(sizes.value));
    row.append(sizes);
  }
  pop.append(row);
  const emphasis = $el("div");
  emphasis.className = "choices";
  for (const [i, label] of ["Bold", "Italic", "Underline"].entries()) {
    const mask = 1 << i,
      b = button(label[0], () => {
        const traits = currentFormat(table).traits ^ mask;
        changeFormat(table, "traits", traits);
        b.setAttribute("aria-pressed", String(Boolean(traits & mask)));
      });
    b.setAttribute("aria-label", label);
    b.title = label;
    b.setAttribute("aria-pressed", String(Boolean(f.traits & mask)));
    emphasis.append(b);
  }
  pop.append(emphasis);
  choices(
    "Alignment",
    ["Auto", "Left", "Center", "Right"],
    f.alignment,
    (value) => changeFormat(table, "alignment", value),
  );
  if (!table)
    slider(
      "Type size",
      "textSize",
      8,
      36,
      1,
      (n) => n + " pt",
      f.size,
      (n) => changeFormat(false, "size", n),
    );
}
function tablePicker() {
  const grid = $el("div"),
    label = $el("small", "Insert by grid");
  grid.className = "insert-grid";
  grid.setAttribute("role", "group");
  grid.setAttribute("aria-label", "Insert table by grid");
  const cols = 8,
    rows = 5;
  const highlight = (x, y) => {
    label.textContent = x + " columns × " + y + " rows";
    [...grid.children].forEach((b, i) => {
      b.tabIndex = i === (y - 1) * cols + x - 1 ? 0 : -1;
      b.classList.toggle("lit", i % cols < x && Math.floor(i / cols) < y);
    });
  };
  for (let y = 1; y <= rows; y++)
    for (let x = 1; x <= cols; x++) {
      const b = button("", () => {
        setting("rows", y);
        setting("columns", x);
        const size = [Math.min(W - 8, x * 72), y * 28],
          origin = insertion();
        origin[0] = Math.min(origin[0], W - size[0]);
        closePop();
        replaceObjects(
          [
            newTable(
              [origin, size],
              y,
              x,
              uid(),
              formatTarget(true)?.table.header ?? settings().header,
            ),
          ],
          "Insert table",
        );
      });
      b.setAttribute(
        "aria-label",
        "Insert " + x + (x === 1 ? " column by " : " columns by ") + y + (y === 1 ? " row" : " rows"),
      );
      b.tabIndex = x === 1 && y === 1 ? 0 : -1;
      b.onpointerenter = b.onfocus = () => highlight(x, y);
      b.onkeydown = (e) => {
        const d = {
          ArrowLeft: [-1, 0],
          ArrowRight: [1, 0],
          ArrowUp: [0, -1],
          ArrowDown: [0, 1],
        }[e.key];
        if (!d) return;
        e.preventDefault();
        e.stopPropagation();
        grid.children[
          (clamp(y + d[1], 1, rows) - 1) * cols + clamp(x + d[0], 1, cols) - 1
        ].focus();
      };
      grid.append(b);
    }
  pop.append(label, grid);
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
    refresh();
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
  formatOptions(true);
}
function toolOptions(anchor, id) {
  openPop(anchor, "tool", toolNames[id][0], () => {
    const p = settings();
    let redrawSample;
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
        const points = [];
        const stylus = devices[device][1];
        for (let i = 0; i <= 100; i++) {
          const t = i / 100;
          const force = 0.04 + 0.94 * Math.sin(Math.PI * t) ** 2;
          const position = [6 + t * 228, 13.5 - 7 * Math.sin(t * Math.PI * 3)];
          const last = points.at(-1);
          const distance = last ? dist(last.position, position) : 0;
          const elapsed = s.nib === "Brush" ? 0.005 + force * 0.008 : 0.008 + force * 0.018;
          const radius = sampledRadius(s, stylus ? force : null, last?.radius,
            distance, elapsed, i === 100, stylus);
          const motion = s.nib === "Brush" ? brushMotion(last, distance, elapsed, s.width) : {};
          points.push({position, radius, ...motion});
        }
        const sampleInk = makeInk(fittedInk(points, s, [], true, true), inks[s.ink]);
        sampleInk.inkNib = inkNib(s);
        if (s.nib === "Pen") sampleInk.ballpointWidth = s.width;
        ctx.save();
        ctx.scale(2, 2);
        paintFootprint(ctx, inkFootprint(sampleInk), inks[s.ink], s.nib === "Pen" ? s.penFlow : 1);
        ctx.restore();
      }
      grainReady.then(() => { if (sample.isConnected) showSample(); });
      redrawSample = showSample;
      showSample();
      pop.oninput = () => queueMicrotask(showSample);
      choices("Writing tip", ["Pen", "Brush", "Fineliner", "Gel", "Fountain", "Pencil"], p.nib, (v) => {
        setting("nib", v);
        toolOptions(anchor, id);
      });
      if (p.nib === "Brush") choices("Brush finish", ["Inked", "Dry"], p.brushFinish, (value) => {
        setting("brushFinish", value);
        toolOptions(anchor, id);
      });
      const supported = p.nib !== "Fineliner";
      const toggle = checkOption(
        supported && !devices[device][1] ? "Use stroke speed" : "Use pen pressure",
        supported && p.usePressure,
        (v) => {
          setting("usePressure", v);
          toolOptions(anchor, id);
        },
      );
      toggle.disabled = !supported;
      slider("Width", "width", 0.7, 6, 0.1, (x) => x.toFixed(1) + " pt");
      if (p.nib === "Pen") slider("Ink flow", "penFlow", 0.25, 1, 0.01, (x) => Math.round(x * 100) + "%");
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
          (x) => (x === 1 ? "Linear" : x < 1 ? "Soft" : "Firm") + " · " + x.toFixed(2),
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
      choices("Shape", ["Line", "Arrow", "Box", "Oval", "X–Y axes"], p.shape, (x) =>
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
    if (id === "table") { tablePicker(); tableOptions(); }
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
        (x) => {
          setting("erase", x);
          toolOptions(anchor, id);
        },
      );
      if (p.erase === "Regular" || p.erase === "Stroke")
        slider("Contact diameter", "diameter", 6, 36, 1, (x) => x + " pt");
    }
    if (id === "text") {
      checkOption("Insert code block", p.code, (v) => setting("code", v));
      formatOptions(false);
    }
    if (
      ["brush", "marker", "shapes"].includes(id) &&
      ($("inks").hidden || getComputedStyle($("inks")).display === "none")
    )
      penColors(redrawSample);
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
let lastNotebookID, pausedView;
async function showStartScreen() {
  finishText();
  finishGesture();
  recordView(true);
  await flush();
  pausedView = positionState();
  lastNotebookID = book.id;
  closePop();
  launcher.recent(title, true);
  $("welcome").hidden = false;
  document.body.classList.add("launching");
}
let enteringNotebook = false;
async function enterFromLauncher(action) {
  if (enteringNotebook) return;
  enteringNotebook = true;
  try {
    await openLauncherChoice(action);
  } finally {
    enteringNotebook = false;
  }
}
async function openLauncherChoice(action) {
  if (action === "open") { $("file").click(); return; }
  if (action === "new") { await newBook(); return; }
  if (!book || book.id !== lastNotebookID) { await openStored(lastNotebookID); return; }
  $("welcome").hidden = true;
  document.body.classList.remove("launching");
  refresh();
  resize();
  if (pausedView) view.scrollTo(pausedView.x * scale, pausedView.y * scale);
  draw();
}
function settingsMenu() {
  openPop($("settings"), "device", "Options", () => {
    pop.append($el("small", deviceLabel()));
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
  const records = await library().catch(() => {
    notify("The local library is unavailable. You can still download your open notebook.");
    return [];
  });
  openPop($("files"), "files", "Notebook", () => {
    menuAction("New notebook", newBook);
    menuAction("Open notebook or PDF…", () => $("file").click());
    if (bundledIPad) menuAction("Open sample exercise", async () => {
      const response = await fetch("./series-circuit.gridnote");
      if (!response.ok) throw new Error("The sample exercise could not be opened.");
      await importBook(new File([await response.blob()], "Series circuit.gridnote"));
    });
    menuAction("Notebook launcher…", showStartScreen);
    menuAction("Help & About", () =>
      window.open(
        "./guide.html",
        "_blank",
        "noopener",
      ),
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
      menuAction("Clear writing on this page", () => clearWriting("handwriting", currentPage()));
      menuAction("Remove typed text…", () =>
        openPop($("files"), "clear", "Remove typed text", () => {
          menuAction("This page", () => clearWriting("typedText", currentPage()));
          menuAction("All pages", () => clearWriting("typedText"));
        }),
      );
      menuAction("Clear writing on all pages", () => clearWriting("handwriting"));
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
    const offline = $el("small", $("offline-status").textContent);
    offline.id = "offline-menu-status";
    pop.append(offline);
    if (rest.length) {
      pop.append($el("hr"), $el("small", "Recent notebooks"));
      for (const row of rest) menuAction(row.title, () => openStored(row.id));
    }
  });
}
function fitSelectedImage() {
  const image = selected()[0];
  if (!image || selection.size !== 1 || kind(image) !== "image") return;
  const [[, y], [w, h]] = image.frame;
  const factor = Math.min((W - 4 * G) / w, (H - 4 * G) / h);
  const width = w * factor,
    height = h * factor,
    top = Math.floor(y / H) * H;
  setObjects(
    book.objects.map((o) =>
      o.id === image.id
        ? {
            ...o,
            layoutFrame: undefined,
            frame: [
              [
                (W - width) / 2,
                top + clamp(y - top, 2 * G, H - height - 2 * G),
              ],
              [width, height],
            ],
          }
        : o,
    ),
    "Fit image to page",
  );
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
    if (selection.size === 1 && kind(selected()[0]) === "image")
      menuAction("Fit image to page", fitSelectedImage);
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
  const startPage = currentPage();
  const notebookID = book.id;
  const filename = title + (book.sourcePDF ? " - Annotated" : "") + ".pdf";
  const b = preview ? $("preview") : $("export"),
    old = b.textContent;
  $("preview").disabled = $("export").disabled = true;
  try {
    const bytes = await makePDF(book, source, (p, n) => (b.textContent = p + "/" + n));
    const file = new File([bytes], filename, { type: "application/pdf" });
    if (!preview) {
      download(file, file.name);
      return;
    }
    if (book.id !== notebookID || !$("welcome").hidden) return;
    const document = await readPDF(bytes);
    if (book.id !== notebookID || !$("welcome").hidden) {
      await document.destroy();
      return;
    }
    pdfPreview = document;
    previewFile = file;
    pdfIndex = clamp(startPage, 0, document.numPages - 1);
    $("pdfshare").hidden = !canSharePDF();
    $("pdfshare").textContent = bundledIPad ? "Share or save PDF" : "Share PDF";
    $("pdfsave").hidden = bundledIPad;
    $("pdfmodal").showModal();
    await updatePreview();
  } finally {
    busyPDF = false;
    b.textContent = old;
    $("preview").disabled = $("export").disabled = false;
  }
}
$("solve").onclick = async () => {
  const closingSingle = popupKind === "single-study";
  closePop();
  if (closingSingle) return;
  finishText();
  finishGesture();
  const b = $("solve"),
    seq = ++studySequence;
  if (studyItems.length) {
    clearStudyHighlights();
    draw();
    return;
  }
  const page = currentPage(),
    id = book.id,
    rev = book.revision;
  b.textContent = "Scanning…";
  b.disabled = true;
  try {
    const result = lastScan?.book === book && lastScan.page === page
      ? lastScan.result : await scanProblems(book, source, page);
    const { found, error } = result;
    if (
      seq !== studySequence ||
      id !== book.id ||
      rev !== book.revision ||
      page !== currentPage()
    )
      return;
    if (!error) lastScan = { book, page, result };
    studyItems = found;
    highlightedPage = found.length ? page : null;
    b.setAttribute("aria-pressed", String(!!found.length));
    draw();
    if (found.length === 1) {
      openPop(b, "single-study", "Solve", () => studyContent(pop, found[0]));
      return;
    }
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
function canSharePDF() {
  if (bundledIPad) return true;
  try {
    return (
      typeof navigator.share === "function" &&
      navigator.canShare?.({ files: [previewFile] })
    );
  } catch {
    return false;
  }
}
$("pdfshare").onclick = async () => {
  try {
    if (bundledIPad) savePDF();
    else if (canSharePDF()) await navigator.share({ files: [previewFile] });
    else savePDF();
  } catch (e) {
    if (e.name !== "AbortError")
      notify("Sharing failed. Use Save PDF to keep a copy.");
  }
};
function savePDF() {
  if (previewFile) download(previewFile, previewFile.name);
}
$("pdfmodal").addEventListener("close", () => {
  if ($("pdfmodal").open) return;
  ++previewEpoch;
  const previous = pdfPreview;
  pdfPreview = previewFile = null;
  $("pdfcanvas").width = $("pdfcanvas").height = 0;
  $("pdfcount").textContent = "";
  if (previous) run(() => previous.destroy());
});
async function updatePreview() {
  const token = ++previewEpoch, n = pdfIndex, doc = pdfPreview;
  if (!doc) return;
  let canvas;
  try {
    canvas = await pdfBitmap(doc, n,
      Math.min(1450, (innerWidth - 30) * Math.min(2, devicePixelRatio || 1)));
  } catch (error) {
    if (token === previewEpoch) throw error;
    return;
  }
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
  if (document.body.classList.contains("launching")) return;
  const mod = e.metaKey || e.ctrlKey;
  if (e.key === "Escape" && !pop.hidden) {
    e.preventDefault();
    closePop();
    sheet.focus({ preventScroll:true });
    return;
  }
  if (isEntry(e.target)) {
    if (e.target === editor && editing?.parent && e.key === "Tab" && !mod && !e.altKey) {
      e.preventDefault();
      advanceCell(e.shiftKey ? -1 : 1);
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
  if (document.querySelector("dialog[open]")) return;
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
function clearWriting(kindToRemove, page = null) {
  finishText();
  finishGesture();
  const next = book.objects.flatMap((o) => {
    const matches = kindToRemove === "handwriting"
      ? kind(o) === "ink" && o.instrument == null
      : kind(o) === "text" && !o.table && o.codeStyle == null;
    if (!matches) return [o];
    return page == null ? [] : cleared([o], page);
  });
  if (next.length === book.objects.length && next.every((o, i) => o === book.objects[i])) return;
  setObjects(next, kindToRemove === "typedText" ? "Remove typed text" : "Clear writing");
  selection.clear();
  refresh();
}
$("code-toggle").onclick = () => {
  const id = editing?.object.id || selected()[0]?.id;
  finishText();
  const o = book.objects.find(x => x.id === id);
  if (o) selection = new Set([o.id]);
  if (o?.codeStyle != null)
    setObjects(
      book.objects.map((q) =>
        q.id === o.id ? { ...q, codeStyle: !q.codeStyle } : q,
      ),
      "Toggle syntax colors",
    );
};
const iconModes = {
  brush: { Pen: "pen", Brush: "brush", Fineliner: "fineliner", Gel: "gel", Fountain: "fountain", Pencil: "pencil" },
  selector: { Tap: "tap", Rectangle: "box-select", Lasso: "lasso" },
  eraser: { Regular: "regular", Stroke: "stroke", Rectangle: "region-erase", Lasso: "lasso-erase" },
  shapes: { Line: "line", Arrow: "arrow", Box: "box", Oval: "oval", "X–Y axes": "axes" },
  text: { Auto: "text", Left: "left", Center: "center", Right: "right", Code: "code" },
  table: { "With header": "table-header", "Plain": "table" },
};
function updateToolIcon(id, button, prefs) {
  const mode = { brush: prefs.nib, selector: prefs.select, eraser: prefs.erase,
    text: prefs.code ? "Code" : prefs.alignment, shapes: prefs.shape,
    marker: markerNames[prefs.markerInk], table: prefs.header ? "With header" : "Plain" }[id];
  if (button.dataset.mode === mode) return;
  button.dataset.mode = mode;
  const key = iconModes[id]?.[mode] || "marker";
  button
    .querySelector("use")
    .setAttribute(
      "href",
      "./assets/tools.svg#" + key,
    );
  if (id === "marker") button.querySelector("svg").style.color = rgb(markers[prefs.markerInk]);
  const [family, shortcut] = toolNames[id];
  const label = id === "brush" ? family : family + " · " + mode;
  button.title = label + (shortcut ? " (" + shortcut + ")" : "");
  button.setAttribute("aria-description", mode);
}
const svgNS = "http://www.w3.org/2000/svg";
for (const [id, [label, key]] of Object.entries(toolNames)) {
  const b = button("", () => {
    pickTool(id);
    toolOptions(b, id);
  });
  b.id = "tool-" + id;
  b.title = label;
  b.setAttribute("aria-label", label);
  const mark = document.createElementNS(svgNS, "svg");
  mark.setAttribute("class", "glyph");
  mark.setAttribute("viewBox", "0 0 24 24");
  mark.setAttribute("aria-hidden", "true");
  mark.append(document.createElementNS(svgNS, "use"));
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
      if (tool === "text") {
        if (editing) pickTool("text");
        changeFormat(false,"color",inks[i]);
      } else setting(tool === "marker" ? "markerInk" : "ink", i);
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
$("undo").onmousedown = $("redo").onmousedown = (e) => e.preventDefault();
$("clear-page-writing").onclick = () => {
  closePop();
  clearWriting("handwriting", currentPage());
};
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
grainReady.then(backgroundReady);
const launcher = globalThis.GridnoteLauncher.mount($("welcome"), {
  device: mobileSurface ? "" : deviceLabel(),
  start: action => run(() => enterFromLauncher(action)),
});
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
  const last = await lastNotebookInfo();
  lastNotebookID = last?.id;
  launcher.recent(last?.title, !!last);
}).catch(() => {});
function offlineStatus(message) {
  $("offline-status").textContent = message;
  const inMenu = $("offline-menu-status");
  if (inMenu) inMenu.textContent = message;
}

async function prepareOffline() {
  if (bundledIPad) {
    offlineStatus("Ready offline");
    return;
  }
  if (!("serviceWorker" in navigator)) {
    offlineStatus("Offline setup is unavailable in this browser.");
    return;
  }
  try {
    const registration = await navigator.serviceWorker.register("./sw.js");
    const interrupted = "Offline setup was interrupted. Reopen online to retry.";
    const observe = () => {
      const worker = registration.installing || registration.waiting || registration.active;
      if (!worker) {
        offlineStatus(interrupted);
        return;
      }
      const report = () => {
        if (registration.active?.state === "activated")
          offlineStatus("Ready offline");
        else if (worker.state === "redundant")
          offlineStatus(interrupted);
        else offlineStatus("Preparing for offline use…");
      };
      worker.addEventListener("statechange", report);
      report();
    };
    registration.addEventListener("updatefound", observe);
    observe();
  } catch {
    offlineStatus("Offline setup is unavailable. Reopen online to retry.");
  }
}
prepareOffline();
