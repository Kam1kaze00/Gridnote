import AppKit

func inkLayerOpacity(_ nib: InkNib?) -> (body: CGFloat, detail: CGFloat) {
  if nib?.tip == "Brush", let finish = nib?.finish {
    return finish == .dry ? (0.055, 0.94) : (0.59, 0.96)
  }
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

private func brushEase(_ value: CGFloat) -> CGFloat {
  let x = min(1, max(0, value))
  return x * x * (3 - 2 * x)
}

private func brushNoise(_ x: CGFloat, _ y: CGFloat, _ seed: UInt32) -> CGFloat {
  func hash(_ a: Int, _ b: Int) -> CGFloat {
    var h = UInt32(truncatingIfNeeded: a) &* 374761393 &+ UInt32(truncatingIfNeeded: b) &* 668265263 &+ seed &* 144269
    h = (h ^ (h >> 13)) &* 1274126177
    return CGFloat(h ^ (h >> 16)) / 4294967296
  }
  guard x.isFinite, y.isFinite, abs(x) < 1e15, abs(y) < 1e15 else { return 0.5 }
  let i = Int(floor(x)), j = Int(floor(y))
  let u = brushEase(x-CGFloat(i)), v = brushEase(y-CGFloat(j))
  let a = hash(i,j), b = hash(i,j+1)
  return (a+(hash(i+1,j)-a)*u)*(1-v) + (b+(hash(i+1,j+1)-b)*u)*v
}

extension PaperRenderer {
  private func brushCore(_ points: [InkPoint], nib: InkNib, finish: BrushFinish) -> CGPath {
    let seed = UInt32(truncatingIfNeeded: nib.seed ?? 71)
    if finish == .inked || points.count == 1 {
      var travel: CGFloat = 0
      let core = points.indices.map { i -> InkPoint in
        let p = points[i]
        if i > 0 { travel += p.position.distance(to: points[i-1].position)/nib.width }
        let phase = (p.travel ?? travel)*2.5
        let rim = 0.90 + 0.085*brushNoise(phase/1.2,2,seed)
        return InkPoint(position: p.position, radius: p.radius*rim)
      }
      return outline(core)
    }
    var rows: [InkPoint] = [], fallback: CGFloat = 0
    for i in points.indices {
      let a = points[max(0,i-1)], b = points[i]
      let delta = a.position.distance(to: b.position)
      let steps = Int(min(256, max(1, ceil(delta / max(0.55,nib.width*0.46)))))
      for j in 1...steps {
        let t = CGFloat(j)/CGFloat(steps)
        var row = a.interpolated(to: b, by: t)
        row.travel = ((row.travel ?? (fallback+delta*t)/nib.width)*2.5)
        rows.append(row)
      }
      fallback += delta
    }
    let path = CGMutablePath(), lanes = 11
    var left = Array(repeating: [CGPoint](), count: lanes), right = left
    func close(_ k: Int) {
      if left[k].count > 1 {
        path.addLines(between: left[k])
        for point in right[k].reversed() { path.addLine(to: point) }
        path.closeSubpath()
      }
      left[k].removeAll(keepingCapacity: true)
      right[k].removeAll(keepingCapacity: true)
    }
    for i in rows.indices {
      let r = rows[i], v = rows[min(rows.count-1,i+1)].position - rows[max(0,i-1)].position
      let normal = v.length > 0 ? CGPoint(x: -v.y/v.length, y: v.x/v.length) : CGPoint(x: 0,y: 1)
      let s = r.travel ?? 0, drift = (brushNoise(s/8,0,seed &+ 1)-0.5)*0.30
      let depleted = brushEase((s-6)/38), light = brushEase(1-1.7*r.radius/nib.width)
      let fast = brushEase(((r.speed ?? 215)-65)/230)
      for k in 0..<lanes {
        let n = CGFloat(2*k+1)/CGFloat(lanes)-1, edge = abs(n)
        let hair = brushNoise(s/8.6,(n+drift)*9,seed &+ 5)
        let patch = brushNoise(s/7.4,n*1.6,seed &+ 6)
        let base = 0.085 + 0.22*fast + 0.22*edge + 0.28*depleted*fast + 0.15*light
        let opening = base - 0.20*(1-depleted)*(1-edge) + 0.32*(patch-0.5)
        let half = (1.06/CGFloat(lanes))*(1-brushEase((opening-hair+0.065)/0.25))
        guard half >= 0.003 else { close(k); continue }
        left[k].append(r.position + normal * (r.radius*max(-1,n-half)))
        right[k].append(r.position + normal * (r.radius*min(1,n+half)))
      }
    }
    for k in 0..<lanes { close(k) }
    return path
  }

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
      if let finish = nib.finish {
        return InkFootprint(body: outline(points), core: brushCore(points, nib: nib, finish: finish), nib: nib)
      }
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
