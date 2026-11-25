import AppKit

/// Columns grow to the right and rows grow down, just as they do on the page.
final class TablePicker: NSControl {
  private let columns = 8, rows = 5, pitch: CGFloat = 16
  private var column = 1, row = 1
  var preview: ((Int, Int) -> Void)?
  var insert: ((Int, Int) -> Void)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: CGFloat(columns) * pitch, height: CGFloat(rows) * pitch)
  }
  init() {
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Insert table by grid")
    setAccessibilityHelp("Use the arrow keys to choose columns and rows, then press Return.")
    setAccessibilityValue("1 column, 1 row")
  }
  required init?(coder: NSCoder) { nil }
  private var tracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }
  private func highlight(_ x: Int, _ y: Int) {
    column = min(columns, max(1, x))
    row = min(rows, max(1, y))
    preview?(column, row)
    setAccessibilityValue("\(column) columns, \(row) rows")
    needsDisplay = true
  }
  private func track(_ event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    highlight(Int(floor(p.x / pitch)) + 1, Int(floor(p.y / pitch)) + 1)
  }
  override func mouseMoved(with event: NSEvent) { track(event) }
  override func mouseDragged(with event: NSEvent) { track(event) }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    track(event)
  }
  override func mouseUp(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    track(event)
    insert?(column, row)
  }
  override func accessibilityPerformPress() -> Bool {
    insert?(column, row)
    return true
  }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123: highlight(column - 1, row)
    case 124: highlight(column + 1, row)
    case 125: highlight(column, row + 1)
    case 126: highlight(column, row - 1)
    case 36, 49, 76: insert?(column, row)
    default: super.keyDown(with: event)
    }
  }
  override func draw(_ dirtyRect: CGRect) {
    for y in 0..<rows {
      for x in 0..<columns {
        let rect = CGRect(
          x: CGFloat(x) * pitch + 1, y: CGFloat(y) * pitch + 1, width: pitch - 3, height: pitch - 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        if x < column && y < row {
          appAccent.withAlphaComponent(0.45).setFill()
          path.fill()
        }
        chromeMuted.setStroke()
        path.stroke()
      }
    }
  }
}
