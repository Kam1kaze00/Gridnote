import AppKit

func inkLayerOpacity(_ nib: InkNib?) -> (body: CGFloat, detail: CGFloat) {
  switch nib?.tip {
  case "Brush": return (0.21, 1)
  case "Fountain": return (0.56, 0.81)
  case "Pencil": return (0.20, 0.66)
  default: return (0.43, 1)
  }
}

// A fixed paper tooth makes graphite settle into the same places at every zoom.
// The tile is recorded once by Quartz and can be reused throughout a PDF.
enum PaperTooth {
  static let spacing: CGFloat = 0.43
  static let side = spacing * 24
  static let pattern: CGPattern? = {
    var callbacks = CGPatternCallbacks(version: 0, drawPattern: { _, ctx in
      for y in 0..<24 {
        for x in 0..<24 {
          let n = noise(x + y * 24)
          let patch = noise(x / 2 + y / 2 * 12 + 763)
          guard n % 256 < (patch % 2 == 0 ? 105 : 184) else { continue }
          let w = 0.60 + CGFloat((n >> 8) % 76) / 100
          let h = 0.55 + CGFloat((n >> 16) % 71) / 100
          ctx.addRect(CGRect(x: CGFloat(x) * spacing, y: CGFloat(y) * spacing,
                             width: w * spacing, height: h * spacing))
        }
      }
      ctx.fillPath()
    }, releaseInfo: nil)
    return CGPattern(info: nil, bounds: CGRect(x: 0, y: 0, width: side, height: side),
      matrix: .identity, xStep: side, yStep: side, tiling: .constantSpacing,
      isColored: false, callbacks: &callbacks)
  }()
  private static func noise(_ index: Int) -> UInt32 {
    var v = UInt32(index) &+ 1
    v = (v ^ (v >> 16)) &* 0x45d9f3b
    v = (v ^ (v >> 16)) &* 0x45d9f3b
    return v ^ (v >> 16)
  }
  static func use(_ ink: InkColor, in ctx: CGContext) {
    guard let pattern, let space = CGColorSpace(patternBaseSpace: CGColorSpaceCreateDeviceRGB()) else { return }
    ctx.setFillColorSpace(space)
    var components: [CGFloat] = [ink.r, ink.g, ink.b, 1]
    ctx.setFillPattern(pattern, colorComponents: &components)
  }
}

extension PaperRenderer {
  func materialFootprint(_ points: [InkPoint], nib: InkNib) -> InkFootprint? {
    guard nib.width.isFinite, nib.width > 0, !points.isEmpty else { return nil }
    switch nib.tip {
    case "Fountain":
      // Sweep a broad, angled nib. A dot has the same elliptical footprint as a line end.
      var basis = CGAffineTransform(rotationAngle: .pi / 6).scaledBy(x: 1, y: 0.30)
      let inverse = basis.inverted()
      let local = points.map { InkPoint(position: $0.position.applying(inverse), radius: $0.radius) }
      let body = outline(local).copy(using: &basis)!
      let middle = local.map { p in
        InkPoint(position: p.position + CGPoint(x: 0.17 * p.radius, y: 0),
                 radius: p.radius * min(0.84, max(0.36, 2 * p.radius / nib.width - 0.35)))
      }
      return InkFootprint(body: body, core: outline(middle).copy(using: &basis), nib: nib)
    case "Pencil":
      let grain = points.map { p in
        let coverage = min(1, max(0, (2 * p.radius / nib.width - 0.32) / 1.35))
        return InkPoint(position: p.position, radius: p.radius * (0.36 + 0.64 * coverage))
      }
      return InkFootprint(body: outline(points), core: outline(grain), nib: nib)
    case "Brush":
      let core = CGMutablePath()
      let normals = points.indices.map { i -> CGPoint in
        let d = points[min(points.count - 1, i + 1)].position - points[max(0, i - 1)].position
        return d.length > 0.00001 ? CGPoint(x: -d.y, y: d.x) * (1 / d.length) : CGPoint(x: 0, y: 1)
      }
      // Loaded bristles touch in the middle, with two fine hairs at the outside edge.
      for (offset, size): (CGFloat, CGFloat) in [(-0.23, 0.71), (0.64, 0.115), (0.91, 0.052)] {
        let strand = points.indices.map { i in
          let p = points[i]
          return InkPoint(position: p.position + normals[i] * (p.radius * offset), radius: p.radius * size)
        }
        core.addPath(outline(strand))
      }
      return InkFootprint(body: outline(points), core: core, nib: nib)
    default: return nil
    }
  }
}
