import AppKit

enum ShapeKind: String, CaseIterable {
  case line = "Line"
  case arrow = "Arrow"
  case rectangle = "Box"
  case ellipse = "Oval"
}

struct NotebookTextFormat: Codable, Equatable {
  var size: CGFloat = 14
  var color: InkColor = InkColor.colors[0].1
  var alignment: TypeAlignment = .natural
  var traits = 0  // Bold, italic and underline, in toolbar order.

  func attributes(header: Bool = false, code: Bool = false) -> [NSAttributedString.Key: Any] {
    let weight: NSFont.Weight = traits & 1 != 0 ? .bold : header ? .semibold : .regular
    var font =
      code
      ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
      : NSFont.systemFont(ofSize: size, weight: weight)
    if traits & 2 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment.value
    return [
      .font: font, .foregroundColor: color.ns, .paragraphStyle: paragraph,
      .underlineStyle: traits & 4 != 0 ? NSUnderlineStyle.single.rawValue : 0,
    ]
  }
}

extension NoteObject {
  var textFormat: NotebookTextFormat {
    get {
      guard case .text(_, let color, let size) = content else { return NotebookTextFormat() }
      return .init(
        size: size, color: color, alignment: alignment ?? .natural, traits: textTraits ?? 0)
    }
    set {
      guard case .text(let string, _, _) = content else { return }
      content = .text(string, newValue.color, newValue.size)
      alignment = newValue.alignment
      textTraits = newValue.traits
    }
  }
}

struct TableGrid: Codable, Equatable {
  var rows: Int
  var columns: Int
  var header: Bool
  var cells: [String]
  var formats: [String: NotebookTextFormat]?

  func key(_ index: Int) -> String { "\(index / columns):\(index % columns)" }

  init(rows: Int = 3, columns: Int = 3, header: Bool = true) {
    self.rows = min(40, max(1, rows))
    self.columns = min(16, max(1, columns))
    self.header = header
    cells = Array(repeating: "", count: self.rows * self.columns)
  }
  func resized(rows: Int, columns: Int, header: Bool) -> Self {
    var next = Self(rows: rows, columns: columns, header: header)
    for r in 0..<min(self.rows, next.rows) {
      for c in 0..<min(self.columns, next.columns) where r * self.columns + c < cells.count {
        let i = r * self.columns + c
        next.cells[r * next.columns + c] = cells[i]
        if let format = formats?[key(i)] {
          if next.formats == nil { next.formats = [:] }
          next.formats?[key(i)] = format
        }
      }
    }
    return next
  }
  func cell(_ i: Int, in frame: CGRect) -> CGRect {
    let w = frame.width / CGFloat(columns)
    let h = frame.height / CGFloat(rows)
    return CGRect(
      x: frame.minX + CGFloat(i % columns) * w, y: frame.minY + CGFloat(i / columns) * h, width: w,
      height: h)
  }
}

let markerColors: [(String, InkColor)] = [
  ("Yellow", .init(r: 1, g: 0.83, b: 0.08)), ("Mint", .init(r: 0.22, g: 0.84, b: 0.55)),
  ("Sky", .init(r: 0.18, g: 0.68, b: 1)), ("Coral", .init(r: 1, g: 0.46, b: 0.38)),
  ("Lilac", .init(r: 0.66, g: 0.44, b: 1)),
]

func shapeInk(
  _ start: CGPoint, _ end: CGPoint, shape: ShapeKind, constrained: Bool, width: CGFloat,
  color: InkColor
) -> NoteObject? {
  let delta = end - start
  var tip = end
  if constrained {
    if shape == .arrow || shape == .line {
      let angle = (atan2(delta.y, delta.x) / (.pi / 12)).rounded() * (.pi / 12)
      tip = start + CGPoint(x: cos(angle), y: sin(angle)) * delta.length
    } else {
      let side = min(abs(delta.x), abs(delta.y))
      tip = start + CGPoint(x: delta.x < 0 ? -side : side, y: delta.y < 0 ? -side : side)
    }
  }
  var points = [start, tip]
  switch shape {
  case .line: break
  case .arrow:
    let d = tip - start
    let u = d * (1 / max(0.001, d.length))
    let wing = min(d.length * 0.36, max(8, width * 5))
    let n = CGPoint(x: -u.y, y: u.x) * (wing * 0.43)
    points += [tip - u * wing + n, tip, tip - u * wing - n]
  case .rectangle:
    points = [start, CGPoint(x: tip.x, y: start.y), tip, CGPoint(x: start.x, y: tip.y), start]
  case .ellipse:
    let center = (start + tip) * 0.5
    let r = (tip - start) * 0.5
    let count = max(24, min(360, Int(ceil(max(abs(r.x), abs(r.y)) * 0.9))))
    points = (0...count).map { i in
      let a = 2 * CGFloat.pi * CGFloat(i) / CGFloat(count)
      return center + CGPoint(x: r.x * cos(a), y: r.y * sin(a))
    }
  }
  var o = NoteObject.ink(points.map { InkPoint(position: $0, radius: width / 2) }, color: color)
  o?.instrument = "shape"
  return o
}

enum CodeFormat {
  static let pattern =
    #"(?m)(//[^\n]*|/\*[\s\S]*?(?:\*/|$)|^\s*#(?!include|define|import)[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|(\b(?:if|else|for|while|return|break|continue|def|class|import|from|in|as|let|var|const|func|function|int|float|double|char|void|struct|bool|true|false|True|False|None|null|using|public|private|static|new|switch|case|end|include|define|printf|print|fn|mut|impl|trait|enum|match|package|interface|extends|async|await|yield|with|lambda|try|except|catch|throw|throws|finally|namespace|using|override|protected|final|val|fun|type|interface|SELECT|FROM|WHERE|JOIN|GROUP|ORDER|BY|INSERT|UPDATE|AND|OR|NULL|nil)\b)|(\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)"#
  static let tokens = try! NSRegularExpression(pattern: pattern)
  static let colors = ["526B5F", "9C3929", "5945A5", "155F8E"].map { hex -> NSColor in
    let v = Int(hex, radix: 16)!
    return NSColor(
      srgbRed: CGFloat(v >> 16) / 255, green: CGFloat(v >> 8 & 255) / 255,
      blue: CGFloat(v & 255) / 255, alpha: 1)
  }
  static func attributed(_ text: String, format: NotebookTextFormat, highlighted: Bool)
    -> NSAttributedString
  {
    let value = NSMutableAttributedString(string: text, attributes: format.attributes(code: true))
    if highlighted {
      tokens.enumerateMatches(in: text, range: NSRange(location: 0, length: value.length)) {
        match, _, _ in
        guard let match else { return }
        for i in 1..<match.numberOfRanges where match.range(at: i).location != NSNotFound {
          value.addAttribute(.foregroundColor, value: colors[i - 1], range: match.range)
        }
      }
    }
    return value
  }
  static func recognize(_ value: String) -> (String, Bool) {
    let lines = value.components(separatedBy: "\n")
    if lines.count >= 3, lines[0].hasPrefix("\u{60}\u{60}\u{60}"),
      lines.last?.trimmingCharacters(in: .whitespaces) == "\u{60}\u{60}\u{60}"
    {
      return (lines.dropFirst().dropLast().joined(separator: "\n"), true)
    }
    return (
      value,
      value.range(
        of:
          #"(?m)^\s*(?:#include\s*[<"]|(?:int|void|double)\s+\w+\s*\(|(?:def|func|function|fn|fun|class|interface)\s+\w+\s*\(|(?:const|let|var|val)\s+\w+\s*=|return\s+[A-Za-z_0-9(][^\n;]*;?\s*$|(?:print|printf|console\.log|System\.out\.println)\s*\(|(?:SELECT|select)\s+.+\s+(?:FROM|from)\s+)"#,
        options: .regularExpression) != nil
    )
  }
}

struct AlignGuide: Equatable {
  var a: CGPoint
  var b: CGPoint
  var bounds: CGRect {
    CGRect(
      x: min(a.x, b.x), y: min(a.y, b.y), width: max(1, abs(a.x - b.x)),
      height: max(1, abs(a.y - b.y)))
  }
}
func alignment(
  for moving: CGRect, near targets: [CGRect], tolerance: CGFloat, fixed: CGPoint? = nil
) -> (
  CGPoint, [AlignGuide]
) {
  var adjust = CGPoint.zero
  var guides: [AlignGuide] = []
  for horizontal in [true, false] {
    func marks(_ f: CGRect) -> [CGFloat] {
      horizontal ? [f.minX, f.midX, f.maxX] : [f.minY, f.midY, f.maxY]
    }
    var best = tolerance + 0.00001
    var chosen: AlignGuide?
    for target in targets {
      let span = moving.union(target)
      for m in marks(moving) {
        if let fixed, abs(m - (horizontal ? fixed.x : fixed.y)) < 0.01 { continue }
        for t in marks(target) where abs(t - m) < best {
          best = abs(t - m)
          if horizontal {
            adjust.x = t - m
            chosen = .init(a: CGPoint(x: t, y: span.minY), b: CGPoint(x: t, y: span.maxY))
          } else {
            adjust.y = t - m
            chosen = .init(a: CGPoint(x: span.minX, y: t), b: CGPoint(x: span.maxX, y: t))
          }
        }
      }
    }
    if let chosen { guides.append(chosen) }
  }
  return (adjust, guides)
}

func resizeFeedback(_ frame: CGRect, targets: [CGRect], fixed: CGPoint, tolerance: CGFloat) -> (
  guides: [AlignGuide], matches: [String]
) {
  var guides = alignment(for: frame, near: targets, tolerance: tolerance, fixed: fixed).1
  var matches = [String]()
  for width in [true, false] {
    func distance(_ target: CGRect) -> CGFloat {
      abs(width ? target.width - frame.width : target.height - frame.height)
    }
    guard let target = targets.min(by: { distance($0) < distance($1) }),
      distance(target) <= tolerance
    else { continue }
    matches.append(width ? "W" : "H")
    for f in [frame, target] {
      let a = width ? CGPoint(x: f.minX, y: f.midY) : CGPoint(x: f.midX, y: f.minY)
      let b = width ? CGPoint(x: f.maxX, y: f.midY) : CGPoint(x: f.midX, y: f.maxY)
      let tick = width ? CGPoint(x: 0, y: tolerance) : CGPoint(x: tolerance, y: 0)
      guides.append(.init(a: a, b: b))
      for end in [a, b] { guides.append(.init(a: end - tick, b: end + tick)) }
    }
  }
  return (guides, matches)
}
