import { sourceIndex } from "./engine.mjs";
import {
  intersection,
  padded,
  inkRegions,
  cropImage,
  pdfLines,
} from "./study-geometry.mjs";
import { W, H, kind, overlaps, groupRect } from "./engine.mjs";
import { cellFrame, textFormat, fontFor } from "./blocks.mjs";
import {
  imageOf,
  paintObject,
  pdfBitmap,
  drawPDFImage,
  textLines,
} from "./render.mjs";

let library;
async function loadOCR() {
  if (!library)
    library = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = new URL("./vendor/ocr/tesseract.min.js", import.meta.url);
      script.onload = () => resolve(globalThis.Tesseract);
      script.onerror = () => {
        library = null;
        reject(Error("Could not load the offline text recognizer."));
      };
      document.head.append(script);
    });
  return library;
}
export async function scanProblems(book, source, page) {
  const top = page * H,
    area = [
      [0, top],
      [W, H],
    ],
    objects = book.objects.filter((o) => overlaps(area, o.frame)),
    found = [];
  const ctx = document.createElement("canvas").getContext("2d");
  const add = (text, frame, code = false) => {
    if (overlaps(frame, area) && globalThis.GridnoteSolve.solve(text, code))
      found.push({ text, frame, code });
  };
  for (const o of objects) {
    if (o.table) {
      o.table.cells.forEach((s, i) => add(s, cellFrame(o, i)));
      continue;
    }
    if (kind(o) !== "text") continue;
    const { _0: value, _2: size } = o.content.text;
    if (o.codeStyle != null) {
      add(value, o.frame, true);
      continue;
    }
    const [[x, y], [w]] = o.layoutFrame || o.frame;
    ctx.font = fontFor(textFormat(o));
    let offset = 0;
    for (const line of value.split("\n")) {
      const height = Math.max(1, textLines(ctx, line, w).length) * size * 1.2;
      add(line, [
        [x, y + offset],
        [w, height],
      ]);
      offset += height;
    }
  }
  const other = objects.filter(
    (o) => kind(o) !== "text" && o.instrument !== "marker",
  );
  if (!other.length && sourceIndex(book, page) == null) return { found };
  const sourcePage = sourceIndex(book, page) != null,
    rawLines = [];
  if (sourcePage) {
    // A damaged or missing text layer can still have a readable rendered page.
    const lines = await pdfLines(source, book, page).catch(() => []);
    for (const line of lines) add(line.text, line.frame);
  }
  let scanRect = area;
  if (!sourcePage) scanRect = intersection(padded(groupRect(other), 8), area);
  const c = document.createElement("canvas"),
    [offset, size] = scanRect;
  const f = Math.min(4.2, Math.sqrt(5000000 / Math.max(1, size[0] * size[1])));
  c.width = Math.max(1, Math.ceil(size[0] * f));
  c.height = Math.max(1, Math.ceil(size[1] * f));
  const crop = (rect) => () => cropImage(c, scanRect, f, rect);
  function complete(error) {
    const candidates = [
      ...inkRegions(other, area).map((frame) => ({
        origin: "Handwriting",
        frame,
      })),
      ...other
        .filter((o) => kind(o) === "image")
        .map((o) => ({ origin: "Photo", frame: intersection(o.frame, area) })),
    ];
    if (sourcePage && !found.length)
      candidates.push({ origin: "PDF page", frame: area });
    for (const { origin, frame } of candidates) {
      const within = rawLines.filter((l) => overlaps(frame, l.frame));
      const questions = found.filter(
        (item) =>
          overlaps(frame, item.frame) &&
          globalThis.GridnoteSolve.solve(item.text)?.kind === "Question",
      );
      if (origin === "Photo" && questions.length === 1 && within.length > 1) {
        questions[0].text = within.map((l) => l.text).join("\n");
        questions[0].frame = frame;
        questions[0].crop = crop(frame);
        questions[0].origin = "Photo";
        questions[0].review = true;
        continue;
      }
      if (
        found.some((o) => {
          const [, d] = intersection(o.frame, frame);
          return d[0] * d[1] > 0.75 * frame[1][0] * frame[1][1];
        })
      )
        continue;
      const text = within.map((l) => l.text).join("\n");
      found.push({
        text,
        frame,
        code: false,
        review: true,
        origin,
        crop: crop(frame),
      });
    }
    return { found, error };
  }
  let worker;
  try {
    const g = c.getContext("2d");
    g.scale(f, f);
    g.translate(-offset[0], -offset[1]);
    if (sourceIndex(book, page) != null) {
      const img = await pdfBitmap(
        source,
        book.sourcePageMap?.[page] ?? page,
        c.width,
        book.originalPDFScale,
      );
      drawPDFImage(g, img, page);
    } else {
      g.fillStyle = "white";
      g.fillRect(0, top, W, H);
    }
    for (const o of other) {
      if (kind(o) === "image") await imageOf(o).promise;
      paintObject(g, o);
    }
    const T = await loadOCR(),
      url = (file) => new URL("./vendor/ocr/" + file, import.meta.url).href;
    worker = await T.createWorker("eng", 1, {
      workerPath: url("worker.min.js"),
      corePath: url("tesseract-core-lstm.js"),
      langPath: url(""),
      workerBlobURL: false,
    });
    await worker.setParameters({ tessedit_pageseg_mode: "11" });
    const { data } = await worker.recognize(
      c,
      {},
      { blocks: true, text: true },
    );
    for (const block of data.blocks || [])
      for (const p of block.paragraphs)
        for (const line of p.lines) {
          if (!line.text?.trim()) continue;
          const { x0, y0, x1, y1 } = line.bbox;
          const raw = line.text.trim(),
            original = globalThis.GridnoteSolve.readInk(raw),
            frame = [
              [offset[0] + x0 / f, offset[1] + y0 / f],
              [(x1 - x0) / f, (y1 - y0) / f],
            ];
          rawLines.push({ text: original, frame });
          if (
            found.some(
              (o) => o.text.trim() === original && overlaps(frame, o.frame),
            )
          )
            continue;
          if (globalThis.GridnoteSolve.solve(original)) {
            found.push({
              text: original,
              frame,
              code: false,
              review: original !== raw || line.confidence < 82,
              crop: crop(frame),
            });
            continue;
          }
          if (
            /[0-9].*[+*/=^−×÷]/.test(original) &&
            !/[a-z]{3}/i.test(original)
          ) {
            await worker.setParameters({
              tessedit_pageseg_mode: "7",
              tessedit_char_whitelist: "0123456789 .+-=*/^()?xXyYzZ",
            });
            const left = Math.max(0, x0 - 8),
              topPx = Math.max(0, y0 - 8);
            const corrected = await worker.recognize(c, {
              rectangle: {
                left,
                top: topPx,
                width: Math.min(c.width - left, x1 - x0 + 16),
                height: Math.min(c.height - topPx, y1 - y0 + 16),
              },
            });
            const text = globalThis.GridnoteSolve.readInk(
              corrected.data.text.trim() || original,
            );
            found.push({
              text,
              frame,
              code: false,
              review: true,
              crop: crop(frame),
            });
          }
        }
    return complete();
  } catch (e) {
    return complete("Could not scan image text. " + e.message);
  } finally {
    if (worker) await worker.terminate();
  }
}
export function studyContent(pop, problem) {
  const el = (tag, txt) => {
    const v = document.createElement(tag);
    if (txt != null) v.textContent = txt;
    return v;
  };
  const crop = problem.crop?.();
  if (crop) {
    crop.className = "study-crop";
    crop.setAttribute("aria-label", problem.origin || "Scanned exercise");
    pop.append(crop);
  }
  const input = el("textarea");
  input.value = problem.text;
  input.setAttribute("aria-label", "Recognized exercise");
  input.rows = 3;
  const out = el("div");
  out.className = "study-answer";
  out.setAttribute("aria-live", "polite");
  const row = el("div");
  row.className = "choices";
  const desktop = location.origin === "http://127.0.0.1:48765" && new URL("./", location.href).pathname === "/";
  const localTutor = desktop || (["http://127.0.0.1:8765", "http://localhost:8765"].includes(location.origin) && new URL("./", location.href).pathname === "/");
  const lifetime = new AbortController();
  let current, connected = false;
  const stop = () => { current?.abort(); current = undefined; };
  pop.addEventListener("panelclose", () => { stop(); lifetime.abort(); }, { once: true });
  const result = () => globalThis.GridnoteSolve.solve(input.value, problem.code);
  const local = () => {
    stop();
    if (ai) ai.textContent = "Ask AI";
    input.readOnly = false;
    const r = result();
    out.replaceChildren();
    if (r?.answer != null) {
      const list = el("ol");
      for (const s of r.steps) list.append(el("li", s));
      out.append(list, el("strong", "Answer   " + r.answer));
    } else
      out.append(
        el(
          "p",
          localTutor
            ? "Click Ask AI for a worked explanation."
            : "Edit the exercise and try Solve again, or copy it to use elsewhere.",
        ),
      );
  };
  const action = (name, fn) => {
    const b = el("button", name);
    b.onclick = fn;
    row.append(b);
    return b;
  };
  let ai, accountRow, status, options;
  row.classList.add("study-actions");
  const updateAccount = (value) => {
    connected = value;
    if (!accountRow) return;
    status.textContent = value ? "Using your ChatGPT plan" : "Ask AI uses your ChatGPT plan";
    options.querySelector('[value="disconnect"]').hidden = !value;
    options.querySelector('[value="connect"]').hidden = value;
  };
  async function account(body, signal) {
    const response = await fetch("./api/chatgpt", {
      method: "POST", signal,
      headers: { "Content-Type": "application/json", "X-Gridnote-Request": "1" },
      body: JSON.stringify(body),
    });
    if (!response.ok) throw Error("Gridnote could not reach its account component.");
    return response.json();
  }
  async function requestSolution(mode) {
    stop();
    const controller = new AbortController();
    current = controller;
    const signal = controller.signal;
    const text = input.value;
    const timer = setTimeout(() => controller.abort(), 420000);
    input.readOnly = true;
    ai.textContent = "Cancel";
    try {
      if (desktop && mode !== "server") {
        if (mode === "disconnect" || mode === "connect" || !connected) {
          const disconnect = mode === "disconnect";
          out.textContent = disconnect ? "Disconnecting…" : "Approve Gridnote in your browser. Your answer will appear here.";
          const connection = await account({ action: disconnect ? "disconnect" : "connect" }, signal);
          if (signal.aborted) return;
          updateAccount(connection.connected);
          if (connection.error) throw Error(connection.error);
          if (mode !== "ask") {
            out.textContent = disconnect ? "Disconnected from ChatGPT." : "Connected. Ask AI uses your ChatGPT plan.";
            return;
          }
        }
      }
      out.textContent = desktop && mode !== "server" ? "Solving with your ChatGPT plan…" : "Getting an explanation…";
      const body = { text, image: crop?.toDataURL("image/jpeg", 0.86), kind: result()?.kind || "Question" };
      let reply;
      if (desktop && mode !== "server") {
        reply = await account({ ...body, action: "ask" }, signal);
        if (signal.aborted) return;
        updateAccount(reply.connected);
      } else {
        const response = await fetch("./api/explain", {
          method: "POST", signal, headers: { "Content-Type": "application/json", "X-Gridnote-Request": "1" },
          body: JSON.stringify(body),
        });
        if (!response.headers.get("content-type")?.includes("application/json")) throw Error("The optional study server is unavailable.");
        reply = await response.json();
      }
      if (!signal.aborted) out.textContent = reply.error || reply.answer || "No answer was returned.";
    } catch (e) {
      if (current === controller) out.textContent = signal.aborted ? "Request canceled." : e.message;
    } finally {
      clearTimeout(timer);
      if (current === controller) { current = undefined; input.readOnly = false; ai.textContent = "Ask AI"; }
    }
  }
  action("Solve", local);
  if (localTutor) {
    ai = action("Ask AI", () => {
      if (current) { current.abort(); return; }
      requestSolution("ask");
    });
    ai.title = desktop ? "Send this exercise and its selected image using your ChatGPT plan" : "Ask the configured study server";
  }
  const copy = action("Copy", async () => {
    const fallback = () => {
      input.focus(); input.select();
      out.textContent = "The exercise text is selected. Use your device’s Copy command.";
    };
    try {
      if (crop && typeof ClipboardItem !== "undefined" && navigator.clipboard?.write) {
        const blob = new Promise((resolve, reject) => crop.toBlob(b => b ? resolve(b) : reject(Error()), "image/png"));
        const formats = { "image/png": blob };
        if (input.value) formats["text/plain"] = new Blob([input.value], { type: "text/plain" });
        await navigator.clipboard.write([new ClipboardItem(formats)]);
      } else if (navigator.clipboard && input.value) {
        await navigator.clipboard.writeText(input.value);
      } else { fallback(); return; }
      copy.textContent = "Copied";
      setTimeout(() => { copy.textContent = "Copy"; }, 1400);
    } catch { fallback(); }
  });
  copy.title = "Copy the exercise text and selected image";
  pop.append(input, row);
  if (desktop) {
    accountRow = el("div"); accountRow.className = "study-account";
    status = el("small"); options = el("select");
    options.setAttribute("aria-label", "ChatGPT account options");
    for (const [key, name] of [["","Account"],["connect","Continue with ChatGPT"],["usage","Manage usage…"],["disconnect","Disconnect ChatGPT"],["server","Ask using study server"]]) options.add(new Option(name,key));
    options.onchange = () => {
      const choice = options.value; options.value = "";
      if (choice === "usage") window.open("https://chatgpt.com/settings/usage", "_blank", "noopener,noreferrer");
      else if (choice) requestSolution(choice);
    };
    accountRow.append(status,options); pop.append(accountRow);
    updateAccount(false);
    account({action:"status"}, lifetime.signal).then(value => {
      if (!current && !lifetime.signal.aborted) updateAccount(value.connected);
    }).catch(() => {});
  }
  pop.append(out);
  if (problem.review) {
    out.textContent =
      "Check the recognized text against the image, then choose Solve.";
  } else local();
}
