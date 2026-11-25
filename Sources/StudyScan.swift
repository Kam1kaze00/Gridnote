import AppKit
import PDFKit

struct ScanPageImage {
  let pixels: CGImage
  let frame: CGRect
  let scale: CGFloat

  func crop(_ rect: CGRect) -> CGImage? {
    let f = frame.intersection(rect.insetBy(dx: -3, dy: -3))
    guard !f.isNull else { return nil }
    let pixelRect = CGRect(
      x: (f.minX - frame.minX) * scale, y: (f.minY - frame.minY) * scale, width: f.width * scale,
      height: f.height * scale
    ).integral
    guard let cropped = pixels.cropping(to: pixelRect) else { return nil }
    let factor = min(1, 1500 / CGFloat(max(cropped.width, cropped.height)))
    guard factor < 1,
      let c = CGContext(
        data: nil, width: max(1, Int(CGFloat(cropped.width) * factor)),
        height: max(1, Int(CGFloat(cropped.height) * factor)), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return cropped }
    c.interpolationQuality = .high
    c.draw(cropped, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
    return c.makeImage()
  }
}

func handwritingRegions(_ strokes: [NoteObject], on area: CGRect) -> [CGRect] {
  var groups: [CGRect] = []
  let frames = strokes.compactMap { o -> CGRect? in
    if case .ink = o.content, o.instrument == nil { return o.frame.intersection(area) }
    return nil
  }.filter { !$0.isNull }.sorted { $0.minX < $1.minX }
  for f in frames {
    if let i = groups.lastIndex(where: { g in
      abs(g.midY - f.midY) <= max(4, max(g.height, f.height) * 0.68)
        && g.insetBy(dx: -max(10, min(26, g.height)), dy: -4).intersects(f)
    }) {
      groups[i] = groups[i].union(f)
    } else {
      groups.append(f)
    }
  }
  return groups.filter { $0.width >= 5 && $0.height >= 2 }.sorted { $0.minY < $1.minY }
}

func selectablePDFLines(_ notebook: Notebook, page: Int, area: CGRect) -> [StudyProblem] {
  guard let data = notebook.sourcePDF, let index = notebook.sourceIndex(on: page),
    let source = PDFDocument(data: data)?.page(at: index),
    let ref = source.pageRef, let string = source.string, !string.isEmpty
  else { return [] }
  let crop = ref.getBoxRect(.cropBox)
  let rotated = abs(Int(ref.rotationAngle)) % 180 == 90
  let natural = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
  let factor = min(
    notebook.originalPDFScale == true ? 1 : CGFloat.greatestFiniteMagnitude,
    area.width / max(1, natural.width), area.height / max(1, natural.height))
  let transform = ref.getDrawingTransform(
    .cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true)
  let text = string as NSString
  var i = 0
  var lines: [StudyProblem] = []
  while i < text.length {
    let range = text.lineRange(for: NSRange(location: i, length: 0))
    guard NSMaxRange(range) > i else { break }
    i = NSMaxRange(range)
    guard let selection = source.selection(for: range) else { continue }
    let b = selection.bounds(for: source).applying(transform)
    let f = CGRect(
      x: (area.width - natural.width * factor) / 2 + b.minX * factor,
      y: area.maxY - (area.height - natural.height * factor) / 2 - b.maxY * factor,
      width: b.width * factor, height: b.height * factor)
    let value = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty, f.intersects(area) {
      lines.append(.init(text: value, frame: f.intersection(area), code: false))
    }
  }
  return lines
}
