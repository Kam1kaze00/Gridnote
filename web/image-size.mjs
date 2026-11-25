// Notebook coordinates are PDF points. A density-free bitmap uses the CSS reference pixel.
export function imageSize(bytes, orientedWidth, orientedHeight) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const end = view.byteLength;
  let dx = 0,
    dy = 0,
    orientation = 1;
  function exif(start, limit) {
    if (start + 8 > limit) return;
    const little = view.getUint16(start) === 0x4949;
    const u16 = (p) => view.getUint16(p, little),
      u32 = (p) => view.getUint32(p, little);
    if (u16(start + 2) !== 42) return;
    const ifd = start + u32(start + 4);
    if (ifd + 2 > limit) return;
    let x,
      y,
      unit = 2;
    for (
      let n = 0, p = ifd + 2;
      n < u16(ifd) && p + 12 <= limit;
      n++, p += 12
    ) {
      const tag = u16(p),
        type = u16(p + 2);
      if (u32(p + 4) !== 1) continue;
      if (tag === 274 && type === 3) orientation = u16(p + 8);
      if (tag === 296 && type === 3) unit = u16(p + 8);
      if ((tag === 282 || tag === 283) && type === 5) {
        const k = start + u32(p + 8);
        if (k + 8 > limit || !u32(k + 4)) continue;
        const v = u32(k) / u32(k + 4);
        if (tag === 282) x = v;
        else y = v;
      }
    }
    if ((unit === 2 || unit === 3) && x > 0 && y > 0) {
      dx = x * (unit === 3 ? 2.54 : 1);
      dy = y * (unit === 3 ? 2.54 : 1);
    }
  }
  if (end >= 8 && view.getUint32(0) === 0x89504e47) {
    for (let pos = 8; pos + 12 <= end; ) {
      const length = view.getUint32(pos),
        type = view.getUint32(pos + 4);
      if (pos + 12 + length > end || type === 0x49444154) break;
      if (type === 0x70485973 && length === 9 && bytes[pos + 16] === 1) {
        dx = view.getUint32(pos + 8) * 0.0254;
        dy = view.getUint32(pos + 12) * 0.0254;
      } else if (type === 0x65584966) exif(pos + 8, pos + 8 + length);
      pos += length + 12;
    }
  } else if (end >= 2 && view.getUint16(0) === 0xffd8) {
    for (let pos = 2; pos + 4 <= end && bytes[pos] === 255; ) {
      if (bytes[pos + 1] === 255) {
        pos++;
        continue;
      }
      const marker = bytes[pos + 1],
        len = view.getUint16(pos + 2),
        start = pos + 4,
        next = pos + 2 + len;
      if (marker === 0xda || marker === 0xd9 || len < 2 || next > end) break;
      if (
        marker === 224 &&
        len >= 16 &&
        view.getUint32(start) === 0x4a464946 &&
        !dx
      ) {
        const unit = bytes[start + 7],
          factor = unit === 1 ? 1 : unit === 2 ? 2.54 : 0;
        dx = view.getUint16(start + 8) * factor;
        dy = view.getUint16(start + 10) * factor;
      } else if (
        marker === 225 &&
        len >= 16 &&
        view.getUint32(start) === 0x45786966
      )
        exif(start + 6, next);
      pos = next;
    }
  } else if (end >= 8 && [0x4949, 0x4d4d].includes(view.getUint16(0)))
    exif(0, end);
  if (orientation >= 5 && orientation <= 8) [dx, dy] = [dy, dx];
  const dpi = (d) => (Number.isFinite(d) && d > 0 ? d : 96);
  return [(orientedWidth * 72) / dpi(dx), (orientedHeight * 72) / dpi(dy)];
}

// Start within 15 × 10 cm on A4, leaving space to write in the current viewport.
export function initialImageSize([width, height], visibleWidth, visibleHeight) {
  const ptPerMM = 72 / 25.4;
  const maxWidth = Math.min(150 * ptPerMM, visibleWidth * 0.85);
  const maxHeight = Math.min(100 * ptPerMM, visibleHeight * 0.6);
  const factor = Math.min(1, maxWidth / width, maxHeight / height);
  return [width * factor, height * factor];
}
