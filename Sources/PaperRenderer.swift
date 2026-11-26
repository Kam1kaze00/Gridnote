import AppKit
import ImageIO
import UniformTypeIdentifiers

struct InkFootprint {
  let body: CGPath
  let core: CGPath?
  var nib: InkNib? = nil

  func add(to context: CGContext, core onlyCore: Bool) {
    if onlyCore {
      if let core { context.addPath(core) }
    } else { context.addPath(body) }
  }

  static func paint(color: InkColor, hasCore: Bool, nib: InkNib? = nil, flow: CGFloat = 1, context: CGContext, add: (Bool) -> Void) {
    context.saveGState()
    defer { context.restoreGState() }
    context.setFillColor(color.cg)
    if hasCore {
      context.saveGState()
      context.setAlpha(inkLayerOpacity(nib).body * flow)
      add(false)
      context.fillPath()
      context.restoreGState()
      context.setAlpha(inkLayerOpacity(nib).detail * flow)
      if nib?.tip == "Pencil" { PaperTooth.use(color, in: context) }
    }
    add(hasCore)
    context.fillPath()
  }

  func paint(color: InkColor, flow: CGFloat = 1, context: CGContext) {
    Self.paint(color: color, hasCore: core != nil, nib: nib, flow: flow, context: context) { add(to: context, core: $0) }
  }
}

final class PaperRenderer {
  let pdf: CGPDFDocument?
  private let images = NSCache<NSUUID, ImageBox>()
  private let strokes = NSCache<NSUUID, StrokeBox>()
  private final class StrokeBox {
    let points: [InkPoint]
    let width: CGFloat?
    let path: InkFootprint
    init(points: [InkPoint], width: CGFloat?, path: InkFootprint) {
      self.points = points
      self.width = width
      self.path = path
    }
  }

  private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  init(pdfData: Data? = nil) {
    pdf = pdfData.flatMap { CGDataProvider(data: $0 as CFData) }.flatMap(CGPDFDocument.init)
    images.totalCostLimit = 96 * 1024 * 1024
    strokes.totalCostLimit = 32 * 1024 * 1024
  }

  func draw(
    page index: Int, design: PaperDesign = PaperDesign(), sourceIndex: Int? = nil,
    originalScale: Bool = false, context: CGContext
  ) {
    let rect = CGRect(
      x: 0, y: CGFloat(index) * paperSize.height, width: paperSize.width, height: paperSize.height)
    context.saveGState()
    context.clip(to: rect)
    if let sourceIndex, let page = pdf?.page(at: sourceIndex + 1) {
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(rect)
      context.translateBy(x: 0, y: rect.maxY)
      context.scaleBy(x: 1, y: -1)
      let crop = page.getBoxRect(.cropBox)
      let rotated = abs(Int(page.rotationAngle)) % 180 == 90
      let natural = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
      let fit = min(
        originalScale ? 1 : CGFloat.greatestFiniteMagnitude,
        paperSize.width / max(1, natural.width), paperSize.height / max(1, natural.height))
      context.translateBy(
        x: (paperSize.width - natural.width * fit) / 2,
        y: (paperSize.height - natural.height * fit) / 2)
      context.scaleBy(x: fit, y: fit)
      let transform = page.getDrawingTransform(
        .cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true)
      context.concatenate(transform)
      context.clip(to: page.getBoxRect(.cropBox))
      context.drawPDFPage(page)
    } else {
      context.setFillColor(design.tint.color.cgColor)
      context.fill(rect)
      context.setStrokeColor(CGColor(red: 0.47, green: 0.62, blue: 0.71, alpha: 0.37))
      context.setLineWidth(0.35)
      if design.ruling == .grid {
        for x in stride(from: CGFloat.zero, through: rect.width, by: paperGrid) {
          context.move(to: CGPoint(x: x, y: rect.minY))
          context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
      }
      if design.ruling == .grid || design.ruling == .ruled {
        let spacing = design.ruling == .ruled ? 7 * 72 / 25.4 : paperGrid
        for y in stride(from: rect.minY, through: rect.maxY, by: spacing) {
          context.move(to: CGPoint(x: 0, y: y))
          context.addLine(to: CGPoint(x: rect.width, y: y))
        }
        context.strokePath()
        context.setStrokeColor(CGColor(red: 0.77, green: 0.37, blue: 0.42, alpha: 0.72))
        context.setLineWidth(0.65)
        context.move(to: CGPoint(x: paperGrid * 4, y: rect.minY))
        context.addLine(to: CGPoint(x: paperGrid * 4, y: rect.maxY))
        context.strokePath()
      } else if design.ruling == .dotted {
        context.setFillColor(CGColor(red: 0.44, green: 0.54, blue: 0.6, alpha: 0.52))
        let visible = context.boundingBoxOfClipPath.intersection(rect)
        let x0 = max(0, floor(visible.minX / paperGrid)) * paperGrid
        let y0 = rect.minY + max(0, floor((visible.minY - rect.minY) / paperGrid)) * paperGrid
        for x in stride(from: x0, through: visible.maxX + 0.6, by: paperGrid) {
          for y in stride(from: y0, through: visible.maxY + 0.6, by: paperGrid) {
            context.fillEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
          }
        }
      }
    }
    context.restoreGState()
  }

  func draw(_ object: NoteObject, context: CGContext) {
    switch object.content {
    case .ink(let points, let ink):
      let key = object.id as NSUUID
      let path: InkFootprint
      if let cached = strokes.object(forKey: key), cached.width == object.ballpointWidth, cached.path.nib == object.inkNib, cached.points == points {
        path = cached.path
      } else {
        path = footprint(points, ballpointWidth: object.ballpointWidth, nib: object.inkNib)
        strokes.setObject(
          StrokeBox(points: points, width: object.ballpointWidth, path: path), forKey: key,
          cost: points.count * (path.core == nil ? 80 : 160))
      }
      context.saveGState()
      defer { context.restoreGState() }
      if object.instrument == "marker" {
        context.setAlpha(object.opacity ?? 0.38)
        context.setBlendMode(.multiply)
      }
      path.paint(color: ink, flow: object.opacity ?? 1, context: context)
    case .image(let data):
      let key = object.id as NSUUID
      let cached = images.object(forKey: key)?.image
      guard let image = cached ?? Self.decode(data) else { return }
      if cached == nil {
        images.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
      }
      context.saveGState()
      let layout = object.layoutFrame ?? object.frame
      context.clip(to: object.frame)
      context.translateBy(x: layout.minX, y: layout.maxY)
      context.scaleBy(x: 1, y: -1)
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(origin: .zero, size: layout.size))
      context.restoreGState()
    case .text(let value, _, _):
      context.saveGState()
      context.clip(to: object.frame)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      let layout = object.layoutFrame ?? object.frame
      if let grid = object.table {
        drawTable(grid, in: layout, format: object.textFormat, context: context)
      } else if let highlight = object.codeStyle {
        context.setFillColor(CGColor(gray: 0.965, alpha: 1))
        context.fill(layout)
        CodeFormat.attributed(value, format: object.textFormat, highlighted: highlight).draw(
          with: layout.insetBy(dx: 5, dy: 3), options: [.usesLineFragmentOrigin, .usesFontLeading])
      } else {
        NSAttributedString(string: value, attributes: object.textFormat.attributes())
          .draw(with: layout, options: [.usesLineFragmentOrigin, .usesFontLeading])
      }
      NSGraphicsContext.restoreGraphicsState()
      context.restoreGState()
    }
  }

  private func drawTable(
    _ grid: TableGrid, in f: CGRect, format: NotebookTextFormat, context: CGContext
  ) {
    guard grid.rows > 0, grid.columns > 0 else { return }
    context.setFillColor(CGColor(gray: 1, alpha: 0.95))
    context.fill(f)
    for i in grid.cells.indices {
      let cell = grid.cell(i, in: f)
      let header = grid.header && i < grid.columns
      if header {
        context.setFillColor(CGColor(red: 0.87, green: 0.93, blue: 0.91, alpha: 1))
        context.fill(cell)
      }
      context.setStrokeColor(CGColor(red: 0.42, green: 0.51, blue: 0.53, alpha: 1))
      context.setLineWidth(0.55)
      context.stroke(cell)
      var style = grid.formats?[grid.key(i)] ?? format
      style.size = min(style.size, cell.height * 0.64)
      NSAttributedString(string: grid.cells[i], attributes: style.attributes(header: header))
        .draw(
          with: cell.insetBy(dx: 3, dy: 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
  }

  func footprint(_ points: [InkPoint], ballpointWidth: CGFloat?, nib: InkNib? = nil) -> InkFootprint {
    if let nib, let custom = materialFootprint(points, nib: nib) { return custom }
    let body = outline(points)
    guard let width = ballpointWidth, width.isFinite, width > 0 else {
      return InkFootprint(body: body, core: nil, nib: nib)
    }
    // The ball leaves a narrow track. Increasing load fills more of that track with dense ink.
    let core = points.map { point -> InkPoint in
      let coverage = min(1, max(0, (2 * point.radius / width - 0.74) / 0.36))
      return InkPoint(position: point.position, radius: point.radius * (0.16 + 0.84 * coverage))
    }
    return InkFootprint(body: body, core: outline(core))
  }

  // One pressure-varying outline per stroke. A reversal starts a new round-capped span.
  func outline(_ points: [InkPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    guard points.count > 1 else {
      path.addEllipse(in: first.bounds)
      return path
    }
    var start = 0
    var previous = points[1].position - first.position
    for i in 1..<points.count {
      if i == points.count - 1 {
        addSpan(points[start...i], to: path)
        break
      }
      let next = points[i + 1].position - points[i].position
      if previous.dot(next) < -0.45 * previous.length * next.length {
        addSpan(points[start...i], to: path)
        start = i
      }
      previous = next
    }
    return path
  }

  private func addSpan(_ points: ArraySlice<InkPoint>, to path: CGMutablePath) {
    guard let start = points.first, let end = points.last else { return }
    var right: [CGPoint] = []
    right.reserveCapacity(points.count)
    var firstAngle: CGFloat = 0
    var lastAngle: CGFloat = 0
    for i in points.indices {
      let p = points[i]
      let inVector = p.position - points[max(points.startIndex, i - 1)].position
      let outVector = points[min(points.endIndex - 1, i + 1)].position - p.position
      let u = inVector * (1 / max(inVector.length, 0.000001))
      let v = outVector * (1 / max(outVector.length, 0.000001))
      let sum = u + v
      let normal = CGPoint(x: -sum.y, y: sum.x) * (1 / max(sum.length, 0.000001))
      let direction = i == points.endIndex - 1 ? u : v
      let width = p.radius / max(0.72, normal.dot(CGPoint(x: -direction.y, y: direction.x)))
      let edge = normal * width
      if i == points.startIndex {
        firstAngle = atan2(normal.y, normal.x)
        path.move(to: p.position + edge)
      } else {
        path.addLine(to: p.position + edge)
      }
      right.append(p.position - edge)
      if i == points.endIndex - 1 { lastAngle = atan2(normal.y, normal.x) }
    }
    path.addArc(
      center: end.position, radius: end.radius, startAngle: lastAngle, endAngle: lastAngle - .pi,
      clockwise: true)
    for point in right.reversed().dropFirst() { path.addLine(to: point) }
    path.addArc(
      center: start.position, radius: start.radius, startAngle: firstAngle - .pi,
      endAngle: firstAngle - 2 * .pi, clockwise: true)
    path.closeSubpath()
  }

  func export(_ notebook: Notebook) throws -> Data {
    let output = NSMutableData()
    var media = CGRect(origin: .zero, size: paperSize)
    guard let consumer = CGDataConsumer(data: output as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &media, nil)
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    var pages = Array(repeating: [NoteObject](), count: notebook.usedPages)
    for object in notebook.objects {
      let first = max(0, min(pages.count - 1, Int(floor(object.frame.minY / paperSize.height))))
      let last = max(
        first, min(pages.count - 1, Int(ceil(object.frame.maxY / paperSize.height)) - 1))
      for page in first...last { pages[page].append(object) }
    }
    for (index, objects) in pages.enumerated() {
      let top = CGFloat(index) * paperSize.height
      context.beginPDFPage(nil)
      context.translateBy(x: 0, y: paperSize.height + top)
      context.scaleBy(x: 1, y: -1)
      context.clip(to: CGRect(x: 0, y: top, width: paperSize.width, height: paperSize.height))
      draw(
        page: index, design: notebook.paper(on: index),
        sourceIndex: notebook.sourceIndex(on: index),
        originalScale: notebook.originalPDFScale == true, context: context)
      for object in objects { draw(object, context: context) }
      context.endPDFPage()
    }
    context.closePDF()
    return output as Data
  }

  static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  static func importImage(_ data: Data) throws -> (data: Data, size: CGSize) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = metadata[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = metadata[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0
    else { throw CocoaError(.fileReadCorruptFile) }
    func dpi(_ key: CFString) -> CGFloat {
      guard let density = metadata[key] as? CGFloat, density.isFinite, density > 0 else {
        return 96
      }
      return density
    }
    let orientation = metadata[kCGImagePropertyOrientation] as? Int ?? 1
    let natural = CGSize(
      width: width * 72 / dpi(kCGImagePropertyDPIWidth),
      height: height * 72 / dpi(kCGImagePropertyDPIHeight))
    let size =
      (5...8).contains(orientation) ? CGSize(width: natural.height, height: natural.width) : natural
    if CGImageSourceGetType(source) as String? == UTType.png.identifier && orientation == 1 {
      return (data, size)
    }
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: Int(max(width, height)),
        ] as CFDictionary)
    else { throw CocoaError(.fileReadCorruptFile) }
    let output = NSMutableData()
    guard
      let encoder = CGImageDestinationCreateWithData(
        output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(encoder, image, nil)
    guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
    return (output as Data, size)
  }
}
