// All frames, crops and image data stay on the current device.
export const cameraSupported = () =>
  navigator.maxTouchPoints > 0 &&
  (typeof navigator.mediaDevices?.getUserMedia === "function" ||
    "capture" in document.createElement("input"));
const element = (name, txt) => {
  const e = document.createElement(name);
  if (txt) e.textContent = txt;
  return e;
};
const limit = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

export async function capturePhoto() {
  const modal = element("dialog");
  modal.className = "camera-dialog";
  modal.setAttribute("aria-label", "Take and crop a photo");
  const top = element("div");
  top.className = "pdf-toolbar";
  const heading = element("b", "Take photo"),
    spacer = element("div");
  spacer.className = "spacer";
  const cancel = element("button", "Cancel");
  top.append(heading, spacer, cancel);
  const preview = element("div");
  preview.className = "camera-preview";
  const video = element("video");
  video.autoplay = true;
  video.playsInline = true;
  video.muted = true;
  const board = element("div");
  board.className = "crop-board";
  board.hidden = true;
  const photo = element("canvas"),
    crop = element("div");
  crop.className = "crop-rect";
  crop.tabIndex = 0;
  crop.setAttribute(
    "aria-label",
    "Crop region. Drag the region or its corners. Arrow keys move the region.",
  );
  const handles = ["nw", "ne", "se", "sw"];
  for (const name of handles) {
    const h = element("button");
    h.className = "handle " + name;
    h.dataset.corner = name;
    h.setAttribute("aria-label", "Resize " + name + " corner");
    crop.append(h);
  }
  board.append(photo, crop);
  preview.append(video, board);
  const info = element("p", "Opening rear camera…");
  info.className = "camera-info";
  const actions = element("div");
  actions.className = "pdf-toolbar";
  const retake = element("button", "Retake"),
    reset = element("button", "Full image"),
    choose = element("button", "Use device camera"),
    snap = element("button", "Capture"),
    insert = element("button", "Insert crop");
  snap.className = insert.className = "primary";
  snap.disabled = true;
  retake.hidden = reset.hidden = insert.hidden = choose.hidden = true;
  actions.append(retake, reset, choose, snap, insert);
  const native = element("input");
  native.type = "file";
  native.accept = "image/*";
  native.capture = "environment";
  native.hidden = true;
  modal.append(top, preview, info, actions, native);
  document.body.append(modal);
  modal.showModal();
  let stream = null,
    finished = false,
    drag = null,
    box = [0, 0, 1, 1],
    hasFrame = false;
  const stop = () => {
    if (stream) {
      for (const t of stream.getTracks()) t.stop();
      stream = null;
    }
    video.srcObject = null;
  };
  function updateCrop() {
    Object.assign(crop.style, {
      left: box[0] * 100 + "%",
      top: box[1] * 100 + "%",
      width: (box[2] - box[0]) * 100 + "%",
      height: (box[3] - box[1]) * 100 + "%",
    });
  }
  function sizeBoard() {
    if (!hasFrame) return;
    const k = Math.min(
      (preview.clientWidth - 16) / photo.width,
      (preview.clientHeight - 16) / photo.height,
    );
    board.style.width = Math.max(1, photo.width * k) + "px";
    board.style.height = Math.max(1, photo.height * k) + "px";
  }
  const observer = new ResizeObserver(sizeBoard);
  observer.observe(preview);
  const result = new Promise((resolve, reject) => {
    const end = (value, err) => {
      if (finished) return;
      finished = true;
      stop();
      observer.disconnect();
      document.removeEventListener("visibilitychange", hidden);
      modal.close();
      modal.remove();
      if (err) reject(err);
      else resolve(value);
    };
    const hidden = () => {
      if (document.hidden && stream) {
        stop();
        snap.disabled = true;
        choose.hidden = false;
        info.textContent = "Camera paused. Tap Use device camera to continue.";
      }
    };
    document.addEventListener("visibilitychange", hidden);
    cancel.onclick = () => end(null);
    modal.oncancel = (e) => {
      e.preventDefault();
      end(null);
    };
    function frame(source, w, h) {
      if (!w || !h) {
        info.textContent =
          "Wait for the rear camera to focus, then capture again.";
        return;
      }
      photo.width = w;
      photo.height = h;
      photo.getContext("2d").drawImage(source, 0, 0, photo.width, photo.height);
      stop();
      hasFrame = true;
      box = [0, 0, 1, 1];
      video.hidden = true;
      board.hidden = false;
      snap.hidden = true;
      choose.hidden = true;
      insert.hidden = retake.hidden = reset.hidden = false;
      heading.textContent = "Crop photo";
      info.textContent =
        "Drag the corners to crop. Drag inside to move the frame.";
      sizeBoard();
      updateCrop();
    }
    async function start() {
      stop();
      hasFrame = false;
      video.hidden = false;
      board.hidden = true;
      retake.hidden = reset.hidden = insert.hidden = choose.hidden = true;
      snap.hidden = false;
      snap.disabled = true;
      heading.textContent = "Take photo";
      info.textContent = "Opening rear camera…";
      try {
        const current = await navigator.mediaDevices.getUserMedia({
          audio: false,
          video: {
            facingMode: { exact: "environment" },
            width: { ideal: 2560 },
            height: { ideal: 1920 },
          },
        });
        if (finished) {
          current.getTracks().forEach((t) => t.stop());
          return;
        }
        stream = current;
        video.srcObject = current;
        await video.play();
        snap.disabled = false;
        info.textContent = "Position the exercise in the frame.";
      } catch (e) {
        if (finished) return;
        stop();
        choose.hidden = false;
        snap.hidden = true;
        info.textContent =
          e.name === "NotAllowedError"
            ? "Camera access is off. Use the device camera or choose a saved photo."
            : "Use the device camera to capture the exercise.";
      }
    }
    snap.onclick = () => frame(video, video.videoWidth, video.videoHeight);
    choose.onclick = () => native.click();
    retake.onclick = start;
    reset.onclick = () => {
      box = [0, 0, 1, 1];
      updateCrop();
    };
    native.onchange = async () => {
      const f = native.files?.[0];
      native.value = "";
      if (!f) return;
      const url = URL.createObjectURL(f),
        image = new Image();
      try {
        image.src = url;
        await image.decode();
        frame(image, image.naturalWidth, image.naturalHeight);
      } catch {
        info.textContent =
          "This photo could not be read. Try capturing it again.";
      } finally {
        URL.revokeObjectURL(url);
      }
    };
    const position = (e) => {
      const b = board.getBoundingClientRect();
      return [
        limit((e.clientX - b.left) / b.width, 0, 1),
        limit((e.clientY - b.top) / b.height, 0, 1),
      ];
    };
    crop.onpointerdown = (e) => {
      e.preventDefault();
      crop.setPointerCapture(e.pointerId);
      drag = {
        start: position(e),
        box: [...box],
        corner: e.target.dataset.corner,
      };
    };
    crop.onpointermove = (e) => {
      if (!drag) return;
      const [x, y] = position(e),
        [l, t, r, b] = drag.box,
        dx = x - drag.start[0],
        dy = y - drag.start[1],
        c = drag.corner;
      if (!c) {
        const xx = limit(dx, -l, 1 - r),
          yy = limit(dy, -t, 1 - b);
        box = [l + xx, t + yy, r + xx, b + yy];
      } else {
        box = [
          c.endsWith("w") ? limit(l + dx, 0, r - 0.04) : l,
          c.startsWith("n") ? limit(t + dy, 0, b - 0.04) : t,
          c.endsWith("e") ? limit(r + dx, l + 0.04, 1) : r,
          c.startsWith("s") ? limit(b + dy, t + 0.04, 1) : b,
        ];
      }
      updateCrop();
    };
    crop.onpointerup = crop.onpointercancel = () => {
      drag = null;
    };
    crop.onkeydown = (e) => {
      const delta = {
        ArrowLeft: [-0.01, 0],
        ArrowRight: [0.01, 0],
        ArrowUp: [0, -0.01],
        ArrowDown: [0, 0.01],
      }[e.key];
      if (!delta) return;
      e.preventDefault();
      const dx = limit(delta[0], -box[0], 1 - box[2]),
        dy = limit(delta[1], -box[1], 1 - box[3]);
      box = [box[0] + dx, box[1] + dy, box[2] + dx, box[3] + dy];
      updateCrop();
    };
    insert.onclick = () => {
      const out = element("canvas"),
        sx = Math.round(box[0] * photo.width),
        sy = Math.round(box[1] * photo.height);
      out.width = Math.max(1, Math.round((box[2] - box[0]) * photo.width));
      out.height = Math.max(1, Math.round((box[3] - box[1]) * photo.height));
      out
        .getContext("2d")
        .drawImage(
          photo,
          sx,
          sy,
          out.width,
          out.height,
          0,
          0,
          out.width,
          out.height,
        );
      out.toBlob(
        (blob) =>
          blob
            ? end(blob)
            : end(null, Error("The photo could not be cropped.")),
        "image/png",
      );
    };
    start();
  });
  return result;
}
