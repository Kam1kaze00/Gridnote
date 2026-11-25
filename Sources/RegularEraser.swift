import CoreGraphics

/// Clip an ink centreline against the round footprint swept between two eraser samples.
private func cutInterval(
  _ a: CGPoint, _ b: CGPoint, _ start: CGPoint, _ end: CGPoint, _ radius: CGFloat
) -> ClosedRange<CGFloat>? {
  let delta = b - a
  var intervals: [ClosedRange<CGFloat>] = []
  func add(_ lo: CGFloat, _ hi: CGFloat) {
    let lower = max(0, lo)
    let upper = min(1, hi)
    if upper - lower > 0.000001 { intervals.append(lower...upper) }
  }
  func cap(_ center: CGPoint) {
    let offset = a - center
    let length = delta.dot(delta)
    guard length > 1e-12 else {
      if offset.dot(offset) < radius * radius { add(0, 1) }
      return
    }
    let t = -offset.dot(delta) / length
    let near = offset + delta * t
    let square = (radius * radius - near.dot(near)) / length
    if square > 0 {
      let width = sqrt(square)
      add(t - width, t + width)
    }
  }
  cap(start)
  let length = start.distance(to: end)
  if length > 1e-8 {
    cap(end)
    let axis = (end - start) * (1 / length)
    let normal = CGPoint(x: -axis.y, y: axis.x)
    let offset = a - start
    var lo: CGFloat = 0
    var hi: CGFloat = 1
    for (p, v, lower, upper) in [
      (offset.dot(axis), delta.dot(axis), 0, length),
      (offset.dot(normal), delta.dot(normal), -radius, radius),
    ] {
      if abs(v) < 1e-10 {
        if p < lower || p > upper {
          hi = -1
          break
        }
      } else {
        let t = (lower - p) / v
        let u = (upper - p) / v
        lo = max(lo, min(t, u))
        hi = min(hi, max(t, u))
      }
    }
    add(lo, hi)
  }
  guard let lo = intervals.map({ $0.lowerBound }).min(),
    let hi = intervals.map({ $0.upperBound }).max()
  else { return nil }
  return lo...hi
}

extension NoteObject {
  /// nil means that this sweep missed. An empty array means all ink was removed.
  func erasingPart(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> [NoteObject]? {
    guard case .ink(let points, let color) = content, let first = points.first else { return nil }
    if points.count == 1 {
      return distance(first.position, toSegmentFrom: start, to: end) <= radius + first.radius
        ? [] : nil
    }
    var pieces: [NoteObject] = []
    var run: [InkPoint] = [first]
    var changed = false
    func flush() {
      if let ink = Self.ink(run, color: color) {
        var piece = self
        piece.id = ink.id
        piece.frame = ink.frame
        piece.content = ink.content
        pieces.append(piece)
      }
      run.removeAll(keepingCapacity: true)
    }
    for (a, b) in zip(points, points.dropFirst()) {
      guard
        let cut = cutInterval(a.position, b.position, start, end, radius + max(a.radius, b.radius))
      else {
        if run.isEmpty { run.append(a) }
        run.append(b)
        continue
      }
      changed = true
      if cut.lowerBound > 0 {
        if run.isEmpty { run.append(a) }
        run.append(a.interpolated(to: b, by: cut.lowerBound))
        flush()
      } else if run.count > 1 {
        flush()
      } else {
        run.removeAll()
      }
      if cut.upperBound < 1 { run = [a.interpolated(to: b, by: cut.upperBound), b] }
    }
    guard changed else { return nil }
    flush()
    return pieces
  }
}
