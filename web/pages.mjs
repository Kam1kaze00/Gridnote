import {
  W,
  H,
  kind,
  paper,
  pageCount,
  sourceIndex,
  overlaps,
} from "./engine.mjs";
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
  const buttons = panel.querySelectorAll("[data-action]");
  for (const b of buttons) b.onclick = () => {
    const action = b.dataset.action;
    if (active < count) change(action, active);
    else if (action === "insert") change("add", active);
  };
  async function thumbnail(canvas, book, source, page) {
    const g = canvas.getContext("2d"),
      top = page * H,
      area = [
        [0, top],
        [W, H],
      ];
    g.scale(canvas.width / W, canvas.height / H);
    g.translate(0, -top);
    const src = sourceIndex(book, page);
    if (src !== null && source)
      drawPDFImage(
        g,
        await pdfBitmap(source, src, canvas.width, book.originalPDFScale),
        page,
      );
    else paintPaper(g, page, paper(book, page));
    for (const o of book.objects) {
      if (!overlaps(area, o.frame)) continue;
      if (kind(o) === "image") await imageOf(o).promise;
      paintObject(g, o);
    }
  }
  window.addEventListener("gridnote-paper-loaded", () => { signature = ""; paint(); });
  function paint() {
    if (panel.hidden || !document) return;
    const first = Math.max(0, Math.floor(list.scrollTop / 130) - 1),
      last = Math.min(count, first + Math.ceil(list.clientHeight / 130) + 3);
    const key = [document.id, revision, first, last].join("/");
    if (signature !== key) {
      signature = key;
      rows.replaceChildren();
      rows.style.height = count * 130 + "px";
      for (let i = first; i < last; i++) {
        const b = window.document.createElement("button"),
          c = window.document.createElement("canvas");
        b.className = "page-thumb";
        b.style.top = i * 130 + "px";
        b.dataset.page = i;
        b.setAttribute("aria-label", "Go to page " + (i + 1));
        b.onclick = () => jump(i);
        b.draggable = true;
        b.ondragstart = () => {
          drag = i;
        };
        b.ondragend = () => {
          drag = null;
        };
        b.ondragover = (e) => {
          if (drag != null) e.preventDefault();
        };
        b.ondrop = (e) => {
          e.preventDefault();
          if (drag != null && drag !== i) change("move", drag, i);
          drag = null;
        };
        c.width = 150;
        c.height = 212;
        b.append(c, String(i + 1));
        rows.append(b);
        thumbnail(c, document, pdf, i).catch(
          () => (c.title = "Preview unavailable"),
        );
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
    if (panel.hidden) return;
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
