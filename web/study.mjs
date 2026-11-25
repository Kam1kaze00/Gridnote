import { sourceIndex } from "./engine.mjs";
import {
  intersection,
  padded,
  inkRegions,
  cropImage,
  pdfLines,
} from "./study-geometry.mjs";
import { W, H, kind, overlaps, groupRect } from "./engine.mjs";
import { cellFrame } from "./blocks.mjs";
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
    if (overlaps(frame, area) && GridnoteSolve.solve(text, code))
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
    ctx.font = size + "px Arial";
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
          GridnoteSolve.solve(item.text)?.kind === "Question",
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
            original = GridnoteSolve.readInk(raw),
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
          if (GridnoteSolve.solve(original)) {
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
            const text = GridnoteSolve.readInk(
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
  const localTutor = [
    "http://127.0.0.1:48765", "http://127.0.0.1:8765", "http://localhost:8765",
  ].includes(location.origin) && new URL("./", location.href).pathname === "/";
  const result = () => GridnoteSolve.solve(input.value, problem.code);
  const local = () => {
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
            ? "Use Ask AI for a worked explanation, or copy this exercise to ChatGPT."
            : "Copy this exercise to ChatGPT for a worked explanation. You can edit the recognized text above.",
        ),
      );
  };
  const action = (name, fn) => {
    const b = el("button", name);
    b.onclick = fn;
    row.append(b);
    return b;
  };
  action("Solve", local);
  if (localTutor) {
    const ai = action("Ask AI", async () => {
      ai.disabled = true;
      out.textContent = "Getting an explanation…";
      try {
        const response = await fetch("./api/explain", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Gridnote-Request": "1",
          },
          body: JSON.stringify({
            text: input.value,
            image: crop?.toDataURL("image/jpeg", 0.86),
            kind: result()?.kind || "Question",
          }),
          signal: AbortSignal.timeout(90000),
        });
        if (!response.headers.get("content-type")?.includes("application/json"))
          throw Error(
            "This installation has no AI server. Use Copy to ChatGPT, or start the study server in the README.",
          );
        const data = await response.json();
        if (!response.ok)
          throw Error(data.error || "The AI server could not answer.");
        out.textContent = data.answer;
      } catch (e) {
        out.textContent = e.message;
      } finally {
        ai.disabled = false;
      }
    });
    ai.title =
      "Send the selected exercise text and its preview image to your configured AI server";
  }
  action("Copy to ChatGPT", () => {
    const prompt = GridnoteSolve.prompt(
      input.value,
      result()?.kind || "Question",
    );
    if (
      crop &&
      typeof ClipboardItem !== "undefined" &&
      navigator.clipboard?.write
    ) {
      const blob = new Promise((res, rej) =>
        crop.toBlob(
          (b) => (b ? res(b) : rej(Error("Cannot copy crop"))),
          "image/png",
        ),
      );
      const pending = navigator.clipboard.write([
        new ClipboardItem({
          "image/png": blob,
          "text/plain": new Blob([prompt], { type: "text/plain" }),
        }),
      ]);
      window.open("https://chatgpt.com/", "_blank", "noopener,noreferrer");
      pending
        .then(
          () =>
            (out.textContent = "Exercise image copied. Paste it into ChatGPT."),
        )
        .catch(() => {
          out.textContent =
            "Copy the exercise image from the preview and paste it into ChatGPT.";
        });
      return;
    }
    window.open("https://chatgpt.com/", "_blank", "noopener,noreferrer");
    if (!navigator.clipboard) {
      input.focus();
      input.select();
      out.textContent = "Copy the selected exercise and paste it into ChatGPT.";
      return;
    }
    navigator.clipboard
      ?.writeText(prompt)
      .then(() => {
        out.textContent = "Exercise copied. Paste it into ChatGPT.";
      })
      .catch(() => {
        input.focus();
        input.select();
        out.textContent =
          "Copy the selected exercise and paste it into ChatGPT.";
      });
  });
  pop.append(input, row, out);
  if (problem.review) {
    out.textContent =
      "Check the recognized text against the image, then choose Solve.";
  } else local();
}
