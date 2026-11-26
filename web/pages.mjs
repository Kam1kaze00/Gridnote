import { W, H, kind, paper, pageCount, sourceIndex } from "./engine.mjs";
import {
  pdfBitmap,
  drawPDFImage,
  paintObject,
  paintPaper,
  imageOf,
} from "./render.mjs";
export function pageSidebar(panel, { jump, change }) {
  const list = panel.querySelector(".page-list"),
    rows = panel.querySelector(".page-rows");
  let document = null,
    pdf = null,
    active = 0,
    signature = "",
    revision = null,
    count = 0,
    drag = null;
  const visibleRows = new Map();
  const buttons = panel.querySelectorAll("[data-action]");
  for (const b of buttons) b.onclick = () => {
    const action = b.dataset.action;
    if (active < count) change(action, active);
    else if (action === "insert") change("add", active);
  };
  function makeRow(page) {
    const b = window.document.createElement("button");
    b.className = "page-thumb";
    b.style.top = page * 130 + "px";
    b.dataset.page = page;
    b.setAttribute("aria-label", "Go to page " + (page + 1));
    b.onclick = () => jump(page);
    b.draggable = true;
    b.ondragstart = () => { drag = page; };
    b.ondragend = () => { drag = null; };
    b.ondragover = e => { if (drag != null) e.preventDefault(); };
    b.ondrop = e => {
      e.preventDefault();
      if (drag != null && drag !== page) change("move", drag, page);
      drag = null;
    };
    b.append(window.document.createElement("canvas"), String(page + 1));
    return { button: b, preview: null };
  }
  function samePreview(a, b) {
    return a && a.source === b.source && a.index === b.index && a.originalScale === b.originalScale
      && a.paper.tint === b.paper.tint && a.paper.ruling === b.paper.ruling
      && a.objects.length === b.objects.length && a.objects.every((o, i) => o === b.objects[i]);
  }
  async function thumbnail(row, page, preview) {
    const canvas = window.document.createElement("canvas");
    canvas.width = 150;
    canvas.height = 212;
    const g = canvas.getContext("2d");
    g.scale(canvas.width / W, canvas.height / H);
    g.translate(0, -page * H);
    if (preview.index !== null && preview.source) {
      const image = await pdfBitmap(preview.source, preview.index, canvas.width, preview.originalScale);
      if (row.preview !== preview) return;
      drawPDFImage(g, image, page);
    } else paintPaper(g, page, preview.paper);
    for (const object of preview.objects) {
      if (kind(object) === "image") {
        await imageOf(object).promise;
        if (row.preview !== preview) return;
      }
      paintObject(g, object);
    }
    if (row.preview === preview) row.button.firstElementChild.replaceWith(canvas);
  }
  window.addEventListener("gridnote-paper-loaded", () => {
    for (const row of visibleRows.values()) row.preview = null;
    signature = "";
    paint();
  });
  function paint() {
    if (panel.hidden || !document) return;
    const first = Math.max(0, Math.floor(list.scrollTop / 130) - 1),
      last = Math.min(count, first + Math.ceil(list.clientHeight / 130) + 3);
    const key = [document.id, revision, first, last].join("/");
    if (signature !== key) {
      signature = key;
      rows.style.height = count * 130 + "px";
      for (const [page, row] of visibleRows) {
        if (page < first || page >= last) {
          row.preview = null;
          row.button.remove();
          visibleRows.delete(page);
        }
      }
      const onPage = Array.from({length: Math.max(0, last - first)}, () => []);
      for (const object of document.objects) {
        const [[x, y], [w, h]] = object.frame;
        if (x + w < 0 || x > W) continue;
        const from = Math.max(first, Math.ceil(y / H) - 1);
        const to = Math.min(last - 1, Math.floor((y + h) / H));
        for (let page = from; page <= to; page++) onPage[page - first].push(object);
      }
      // Insert before the next visible page so keyboard order follows page order.
      let next = null;
      for (let page = last - 1; page >= first; page--) {
        let row = visibleRows.get(page);
        if (!row) {
          row = makeRow(page);
          visibleRows.set(page, row);
          rows.insertBefore(row.button, next);
        }
        next = row.button;
        const preview = { source: pdf, index: sourceIndex(document, page), originalScale: document.originalPDFScale,
          paper: paper(document, page), objects: onPage[page - first] };
        if (samePreview(row.preview, preview)) continue;
        row.preview = preview;
        thumbnail(row, page, preview).catch(() => {
          if (row.preview === preview) row.button.firstElementChild.title = "Preview unavailable";
        });
      }
    }
    for (const b of rows.children)
      b.setAttribute("aria-current", String(Number(b.dataset.page) === active));
    const used = active < count;
    const insert = panel.querySelector('[data-action="insert"]');
    const label = used ? "Insert page after" : "Add this page";
    insert.title = label;
    insert.setAttribute("aria-label", label);
    insert.disabled = used ? count >= 99999 : active >= 99999;
    panel.querySelector('[data-action="delete"]').disabled = !used;
    panel.querySelector('[data-action="up"]').disabled = !used || active <= 0;
    panel.querySelector('[data-action="down"]').disabled = active + 1 >= count;
  }
  list.onscroll = paint;
  return (book, source, page, scroll = false) => {
    if (panel.hidden) {
      if (document) {
        for (const row of visibleRows.values()) row.preview = null;
        visibleRows.clear();
        rows.replaceChildren();
        document = pdf = null;
        signature = "";
      }
      return;
    }
    if (pdf !== source || (book !== document && book.id === document?.id && book.revision === revision)) signature = "";
    if (book !== document || revision !== book.revision) {
      count = pageCount(book);
      revision = book.revision;
    }
    const next = page;
    if (next < count && (scroll || active !== next)) {
      if (
        next * 130 < list.scrollTop ||
        next * 130 + 130 > list.scrollTop + list.clientHeight
      )
        list.scrollTop = next * 130;
    }
    document = book;
    pdf = source;
    active = next;
    paint();
  };
}
