import CoreGraphics
import Foundation

// The map lists the old page at each new position. A nil entry is a fresh sheet.
func arrangedPages(_ notebook: Notebook, order: [Int?]) -> Notebook {
  let height = paperSize.height
  let destinations = Dictionary(
    uniqueKeysWithValues: order.enumerated().compactMap { i, old in old.map { ($0, i) } })
  var next = notebook
  next.minimumPages = max(1, order.count)
  var mapping = order.map { $0.flatMap { notebook.sourceIndex(on: $0) } ?? -1 }
  while mapping.last == -1 { mapping.removeLast() }
  next.sourcePages = mapping.count
  next.sourcePageMap = mapping
  next.pagePaper = Dictionary(
    uniqueKeysWithValues: order.enumerated().compactMap { i, old in
      old.flatMap { notebook.pagePaper?[$0] }.map { (i, $0) }
    })
  next.objects = notebook.objects.flatMap { o -> [NoteObject] in
    let first = max(0, Int(floor(o.frame.minY / height)))
    let last = max(first, Int(ceil(o.frame.maxY / height)) - 1)
    var result: [NoteObject] = []
    var index = first
    while index <= last {
      guard let new = destinations[index] else {
        index += 1
        continue
      }
      let offset = new - index
      var end = index
      while end < last, destinations[end + 1] == end + 1 + offset { end += 1 }
      let top = CGFloat(index) * height
      let bottom = CGFloat(end + 1) * height
      var pieces: [NoteObject]
      if o.frame.minY >= top && o.frame.maxY <= bottom {
        pieces = [o]
      } else if case .ink = o.content {
        pieces = cutInk(o) { $0.position.y < top || $0.position.y >= bottom }
      } else {
        var piece = o
        piece.layoutFrame = o.layoutFrame ?? o.frame
        piece.frame = CGRect(
          x: o.frame.minX, y: max(o.frame.minY, top), width: o.frame.width,
          height: min(o.frame.maxY, bottom) - max(o.frame.minY, top))
        pieces = piece.frame.height > 0 ? [piece] : []
      }
      for var piece in pieces {
        if !result.isEmpty { piece.id = UUID() }
        result.append(
          offset == 0
            ? piece
            : piece.transformed(from: .zero, offset: CGPoint(x: 0, y: CGFloat(offset) * height)))
      }
      index = end + 1
    }
    return result
  }
  return next
}
