import AppKit
import CoreGraphics

let paperSize = CGSize(width: 210 * 72 / 25.4, height: 297 * 72 / 25.4)
let paperGrid = 5 * 72 / 25.4

struct InkColor: Codable, Equatable {
  let r: Double
  let g: Double
  let b: Double

  var cg: CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
  var ns: NSColor { .init(srgbRed: r, green: g, blue: b, alpha: 1) }

  static let colors: [(String, InkColor)] = [
    ("Graphite", .init(r: 0.11, g: 0.14, b: 0.17)),
    ("Blue", .init(r: 0.11, g: 0.33, b: 0.71)),
    ("Teal", .init(r: 0.05, g: 0.40, b: 0.33)),
    ("Red", .init(r: 0.72, g: 0.19, b: 0.23)),
    ("Violet", .init(r: 0.42, g: 0.24, b: 0.66)),
  ]
}

struct InkPoint: Codable, Equatable {
  var position: CGPoint
  var radius: CGFloat
  // Travel in nib widths keeps paper marks in place when the stroke is resized or split.
  var travel: CGFloat? = nil
  var speed: CGFloat? = nil

  mutating func recordBrushMotion(after previous: InkPoint?, width: CGFloat, elapsed: Double) {
    let distance = previous.map { $0.position.distance(to: position) } ?? 0
    travel = (previous?.travel ?? 0) + distance / width
    let velocity = min(1200, distance / max(0.001, elapsed))
    speed = (previous?.travel ?? 0) > 0 ? (previous?.speed ?? velocity)*0.72 + velocity*0.28 : velocity
  }

  func interpolated(to other: Self, by t: CGFloat) -> Self {
    .init(
      position: position + (other.position - position) * t,
      radius: radius + (other.radius - radius) * t,
      travel: travel.map { $0 + ((other.travel ?? $0) - $0) * t },
      speed: speed.map { $0 + ((other.speed ?? $0) - $0) * t })
  }
}

enum BrushFinish: String, Codable, CaseIterable { case inked = "Inked", dry = "Dry" }

struct InkNib: Codable, Equatable {
  let tip: String
  var width: CGFloat
  var finish: BrushFinish? = nil
  var seed: Int? = nil
  var textured: Bool? = nil
  var materialVersion: Int? = nil
}

struct NoteObject: Codable, Equatable, Identifiable {
  enum Content: Codable, Equatable {
    case ink([InkPoint], InkColor)
    case image(Data)
    case text(String, InkColor, CGFloat)
  }

  var id = UUID()
  var frame: CGRect
  var content: Content
  var alignment: TypeAlignment? = nil
  var textTraits: Int?
  var instrument: String?
  var opacity: Double?
  var ballpointWidth: CGFloat?
  var inkNib: InkNib?
  var table: TableGrid?
  var codeStyle: Bool?
  var layoutFrame: CGRect? = nil

  static func ink(_ points: [InkPoint], color: InkColor, id: UUID = UUID()) -> Self? {
    guard let first = points.first else { return nil }
    let frame = points.reduce(first.bounds) { $0.union($1.bounds) }
    return .init(id: id, frame: frame, content: .ink(points, color))
  }

  func transformed(from anchor: CGPoint, scale: CGFloat = 1, offset: CGPoint) -> Self {
    var result = self
    if case .ink(let points, let color) = content {
      let ink = points.map {
        InkPoint(
          position: anchor + ($0.position - anchor) * scale + offset, radius: $0.radius * scale,
          travel: $0.travel, speed: $0.speed)
      }
      guard let moved = Self.ink(ink, color: color, id: id) else { return self }
      result.frame = moved.frame
      result.content = moved.content
      result.inkNib?.width *= scale
      result.ballpointWidth = ballpointWidth.map { $0 * scale }
      return result
    }
    result.frame = CGRect(
      origin: anchor + (frame.origin - anchor) * scale + offset,
      size: CGSize(width: frame.width * scale, height: frame.height * scale))
    if let layoutFrame {
      result.layoutFrame = CGRect(
        origin: anchor + (layoutFrame.origin - anchor) * scale + offset,
        size: CGSize(width: layoutFrame.width * scale, height: layoutFrame.height * scale))
    }
    if case .text(let value, let color, let size) = content {
      result.content = .text(value, color, size * scale)
      result.table?.formats = table?.formats?.mapValues { format in
        var copy = format
        copy.size *= scale
        return copy
      }
    }
    return result
  }

  func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
    guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
    guard case .ink(let points, _) = content else { return true }
    if points.count == 1, let first = points.first {
      return first.position.distance(to: point) <= first.radius + tolerance
    }
    return zip(points, points.dropFirst()).contains { a, b in
      distance(point, toSegmentFrom: a.position, to: b.position) <= max(a.radius, b.radius)
        + tolerance
    }
  }
}

struct Notebook: Codable {
  var version = 1
  var id = UUID()
  var revision: UInt64 = 0
  var sourcePDF: Data?
  var sourcePages: Int = 0
  var originalPDFScale: Bool?
  var minimumPages: Int?
  var sourcePageMap: [Int]?
  var objects: [NoteObject] = []
  var defaultPaper: PaperDesign?
  var pagePaper: [Int: PaperDesign]?

  func sourceIndex(on page: Int) -> Int? {
    guard page >= 0, page < sourcePages else { return nil }
    let index = sourcePageMap?[page] ?? page
    return index < 0 ? nil : index
  }

  func paper(on page: Int) -> PaperDesign { pagePaper?[page] ?? defaultPaper ?? PaperDesign() }

  var usedPages: Int {
    let bottom = objects.map(\.frame.maxY).max() ?? 0
    return max(
      max(1, minimumPages ?? 1), sourcePages, (pagePaper?.keys.max() ?? -1) + 1,
      Int(ceil(bottom / paperSize.height)))
  }
}

extension InkPoint {
  var bounds: CGRect {
    CGRect(x: position.x - radius, y: position.y - radius, width: 2 * radius, height: 2 * radius)
  }
}

extension CGPoint {
  static func + (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
  static func - (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
  static func * (lhs: Self, rhs: CGFloat) -> Self { .init(x: lhs.x * rhs, y: lhs.y * rhs) }

  func dot(_ other: Self) -> CGFloat { x * other.x + y * other.y }
  func cross(_ other: Self) -> CGFloat { x * other.y - y * other.x }
  func distance(to other: Self) -> CGFloat { hypot(x - other.x, y - other.y) }
  var length: CGFloat { hypot(x, y) }
}

func distance(_ point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
  let v = b - a
  let t = min(1, max(0, (point - a).dot(v) / max(v.dot(v), 0.000001)))
  return point.distance(to: a + v * t)
}

func pointInPolygon(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
  guard let last = polygon.last, polygon.count >= 3 else { return false }
  var inside = false
  var a = last
  for b in polygon {
    if (a.y > point.y) != (b.y > point.y),
      point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
    {
      inside.toggle()
    }
    a = b
  }
  return inside
}

func segmentsTouch(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, radius: CGFloat = 0)
  -> Bool
{
  let u = b - a
  let v = d - c
  let determinant = u.cross(v)
  if abs(determinant) > 0.000001 {
    let t = (c - a).cross(v) / determinant
    let s = (c - a).cross(u) / determinant
    if (0...1).contains(t), (0...1).contains(s) { return true }
  }
  return min(
    distance(a, toSegmentFrom: c, to: d), distance(b, toSegmentFrom: c, to: d),
    distance(c, toSegmentFrom: a, to: b), distance(d, toSegmentFrom: a, to: b)) <= radius
}

func polygonSelects(_ object: NoteObject, polygon: [CGPoint], bounds: CGRect) -> Bool {
  guard object.frame.intersects(bounds), let last = polygon.last else { return false }
  let edges = Array(zip([last] + polygon.dropLast(), polygon))
  switch object.content {
  case .ink(let points, _):
    if points.contains(where: { pointInPolygon($0.position, polygon) }) { return true }
    if points.count == 1, let dot = points.first {
      return edges.contains { distance(dot.position, toSegmentFrom: $0, to: $1) <= dot.radius }
    }
    return zip(points, points.dropFirst()).contains { a, b in
      edges.contains {
        segmentsTouch(a.position, b.position, $0, $1, radius: max(a.radius, b.radius))
      }
    }
  case .image, .text:
    let f = object.frame
    let corners = [
      CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
      CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY),
    ]
    if corners.contains(where: { pointInPolygon($0, polygon) })
      || polygon.contains(where: f.contains)
    {
      return true
    }
    return zip([corners[3]] + corners.dropLast(), corners).contains { a, b in
      edges.contains { segmentsTouch(a, b, $0, $1) }
    }
  }
}

func smoothedInk(_ raw: [InkPoint], amount: CGFloat, times: [TimeInterval] = [], technical: Bool = false) -> [InkPoint] {
  guard raw.count > 2, amount > 0,
    zip(raw, raw.dropFirst()).reduce(
      CGFloat.zero, { $0 + $1.0.position.distance(to: $1.1.position) }) > 5
  else {
    return raw
  }
  var filtered = raw
  var strength = Array(repeating: CGFloat.zero, count: raw.count)
  // Consecutive turns to the same side describe a loop. An isolated sharp turn is a corner.
  let timed = times.count == raw.count
  var turns = Array(repeating: CGFloat.zero, count: raw.count)
  for i in 1..<(raw.count - 1) {
    let u = raw[i].position - raw[i - 1].position
    let v = raw[i + 1].position - raw[i].position
    guard min(u.length, v.length) > 0.08,
      !timed || max(times[i] - times[i-1], times[i+1] - times[i]) < 0.055 else { continue }
    turns[i] = atan2(u.x*v.y - u.y*v.x, u.dot(v))
  }
  for i in 1..<(raw.count - 1) {
    let a = raw[i - 1].position, b = raw[i].position, c = raw[i + 1].position
    let u = b - a, v = c - b, l = u.length, m = v.length
    guard min(l,m) > 0.08,
      !timed || max(times[i] - times[i-1], times[i+1] - times[i]) < 0.055 else { continue }
    let turn = u.dot(v) / (l*m), angle = turns[i]
    let sign: CGFloat = angle < 0 ? -1 : 1
    let curve = abs(angle) > 0.09 && abs(angle) < 2.35 && min(sign*turns[i-1], sign*turns[i+1]) > 0.055
    let fair = min(1, max(0, (turn - 0.36) / 0.56))
    let correction = a + (c - a) * (l / (l + m)) - b
    let tolerance = min(0.72, max(0.20, raw[i].radius * 0.64))
    var capped = amount * fair * (curve ? 0.14 : 0.67) * min(1, tolerance / max(0.001, correction.length))
    if technical && turn > 0.35 {
      // Technical nibs keep an even track. Straighten only sub-nib chatter.
      let tolerance = min(0.50, raw[i].radius * 0.85)
      let micro = max(0, 1 - correction.length / tolerance) * min(1, (turn - 0.35) / 0.4)
      capped += (amount - capped) * 0.75 * micro
    }
    filtered[i].position = b + correction * capped
    strength[i] = amount * (curve ? 1 : fair)
  }

  var result = [filtered[0]]
  for i in 0..<(filtered.count - 1) {
    let a = filtered[i]
    let b = filtered[i + 1]
    let vector = b.position - a.position
    let length = vector.length
    let previous = filtered[max(0, i - 1)].position
    let next = filtered[min(filtered.count - 1, i + 2)].position
    let incoming = b.position - previous
    let outgoing = next - a.position
    let c1 =
      a.position
      + (vector * (1 - strength[i]) + incoming
        * (strength[i] * length / max(incoming.length, 0.001))) * (1.0 / 3)
    let c2 =
      b.position
      - (vector * (1 - strength[i + 1]) + outgoing
        * (strength[i + 1] * length / max(outgoing.length, 0.001))) * (1.0 / 3)
    let steps = max(1, min(1000, Int(ceil(length / 1.35))))
    for step in 1...steps {
      let t = CGFloat(step) / CGFloat(steps)
      let s = 1 - t
      let first = a.position * (s * s * s) + c1 * (3 * s * s * t)
      let second = c2 * (3 * s * t * t) + b.position * (t * t * t)
      var sample = a.interpolated(to: b, by: t)
      sample.position = step == steps ? b.position : first + second
      result.append(sample)
    }
  }
  return result
}

func cutInk(_ object: NoteObject, intersects: (InkPoint) -> Bool) -> [NoteObject] {
  guard case .ink(let points, let color) = object.content, let first = points.first else {
    return [object]
  }
  var result: [[InkPoint]] = []
  var run: [InkPoint] = []
  var removed = intersects(first)
  if !removed { run.append(first) }
  for (a, b) in zip(points, points.dropFirst()) {
    let steps = max(1, min(5000, Int(ceil(a.position.distance(to: b.position) / 1.25))))
    for step in 1...steps {
      let point = a.interpolated(to: b, by: CGFloat(step) / CGFloat(steps))
      if intersects(point) {
        if !run.isEmpty { result.append(run) }
        run.removeAll(keepingCapacity: true)
        removed = true
      } else {
        run.append(point)
      }
    }
  }
  guard removed else { return [object] }
  if !run.isEmpty { result.append(run) }
  return result.enumerated().compactMap { i, points in
    var piece = NoteObject.ink(points, color: color, id: i == 0 ? object.id : UUID())
    piece?.inkNib = object.inkNib
    piece?.ballpointWidth = object.ballpointWidth
    piece?.instrument = object.instrument
    piece?.opacity = object.opacity
    return piece
  }
}

func removePageWriting(from objects: [NoteObject], page: Int) -> [NoteObject] {
  let top = CGFloat(page) * paperSize.height
  let bottom = top + paperSize.height
  let slice = CGRect(x: 0, y: top, width: paperSize.width, height: paperSize.height)
  return objects.flatMap { object -> [NoteObject] in
    guard object.frame.intersects(slice), object.instrument != "shape" else { return [object] }
    if object.table != nil || object.codeStyle != nil { return [object] }
    if case .ink = object.content, object.frame.minY >= top, object.frame.maxY <= bottom { return [] }
    switch object.content {
    case .image: return [object]
    case .text:
      var pieces: [NoteObject] = []
      if object.frame.minY < top {
        var before = object
        before.layoutFrame = object.layoutFrame ?? object.frame
        before.frame.size.height = top - object.frame.minY
        pieces.append(before)
      }
      if object.frame.maxY > bottom {
        var after = object
        after.layoutFrame = object.layoutFrame ?? object.frame
        after.frame.origin.y = bottom
        after.frame.size.height = object.frame.maxY - bottom
        if !pieces.isEmpty { after.id = UUID() }
        pieces.append(after)
      }
      return pieces
    case .ink:
      return cutInk(object) {
        $0.position.y + $0.radius >= top && $0.position.y - $0.radius < bottom
      }
    }
  }
}

func deletingPage(_ page: Int, from notebook: Notebook) -> Notebook {
  guard (0..<notebook.usedPages).contains(page) else { return notebook }
  return arrangedPages(
    notebook, order: Array(0..<notebook.usedPages).filter { $0 != page }.map { Optional($0) })
}
