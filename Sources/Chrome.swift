import AppKit

let appAccent = NSColor(srgbRed: 0.22, green: 0.69, blue: 0.60, alpha: 1)

let chromeBackground = NSColor(srgbRed: 0.100, green: 0.125, blue: 0.151, alpha: 1)
let chromeToolbar = NSColor(srgbRed: 0.131, green: 0.157, blue: 0.183, alpha: 1)
let chromeBorder = NSColor(srgbRed: 0.202, green: 0.237, blue: 0.266, alpha: 1)
let chromeText = NSColor(srgbRed: 0.91, green: 0.94, blue: 0.95, alpha: 1)
let chromeMuted = NSColor(srgbRed: 0.64, green: 0.70, blue: 0.73, alpha: 1)
let chromeWarning = NSColor(srgbRed: 0.97, green: 0.71, blue: 0.47, alpha: 1)

final class Surface: NSView {
  var didLayout: (() -> Void)?
  private let movable: Bool
  private let color: NSColor

  init(_ color: NSColor, movable: Bool = false) {
    self.movable = movable
    self.color = color
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = color.cgColor
  }

  required init?(coder: NSCoder) { nil }
  func refreshColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColor()
  }
  override var mouseDownCanMoveWindow: Bool { movable }
  override func layout() {
    super.layout()
    didLayout?()
  }
}

final class ChromeButton: NSButton {
  enum Style { case plain, outlined, primary }
  var caption: String {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
      updateAccess()
    }
  }
  var symbol: String? {
    didSet {
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }
  private let fallbackSymbol: String?
  var shortcut: String?
  var style: Style
  var selected = false { didSet { needsDisplay = true } }
  var textColor: NSColor? { didSet { needsDisplay = true } }
  var swatch: NSColor?
  var controlWidth: CGFloat?
  var controlHeight: CGFloat = 30
  private var hover = false
  private var tracking: NSTrackingArea?
  private var regularFont: NSFont { NSFont.systemFont(ofSize: 12, weight: .medium) }
  private var keyFont: NSFont { NSFont.systemFont(ofSize: 9, weight: .medium) }

  init(
    _ caption: String = "", symbol: String? = nil, shortcut: String? = nil,
    style: Style = .plain, target: AnyObject?, action: Selector?
  ) {
    self.caption = caption
    self.fallbackSymbol = symbol
    self.symbol = symbol
    self.shortcut = shortcut
    self.style = style
    super.init(frame: .zero)
    setButtonType(.momentaryChange)
    isBordered = false
    focusRingType = .default
    self.target = target
    self.action = action
    updateAccess()
  }

  required init?(coder: NSCoder) { nil }

  private func updateAccess() {
    if !caption.isEmpty { setAccessibilityLabel(caption) }
  }

  override var intrinsicContentSize: NSSize {
    let width = (caption as NSString).size(withAttributes: [.font: regularFont]).width
    let iconWidth: CGFloat = symbol == nil ? 0 : (caption.isEmpty ? 14 : 20)
    let badgeWidth: CGFloat = shortcut == nil ? 0 : 21
    return CGSize(
      width: controlWidth ?? max(31, ceil(width + iconWidth + badgeWidth + 18)),
      height: controlHeight)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    tracking = area
    addTrackingArea(area)
  }

  override func mouseEntered(with event: NSEvent) {
    hover = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hover = false
    needsDisplay = true
  }
  override func highlight(_ flag: Bool) {
    super.highlight(flag)
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let area = bounds.insetBy(dx: 0.5, dy: 0.5)
    let shape = NSBezierPath(
      roundedRect: area, xRadius: 6, yRadius: 6)
    let pressed = isHighlighted && isEnabled
    if style == .primary, isEnabled {
      (pressed ? appAccent.blended(withFraction: 0.18, of: .white) ?? appAccent : appAccent)
        .setFill()
      shape.fill()
    } else if selected || (hover && isEnabled) || style == .outlined {
      let fill =
        selected
        ? NSColor(srgbRed: 0.17, green: 0.25, blue: 0.24, alpha: 1)
        : chromeBorder.withAlphaComponent(pressed ? 0.95 : 0.57)
      fill.setFill()
      shape.fill()
      if selected || style == .outlined {
        (selected ? appAccent.withAlphaComponent(0.62) : chromeBorder).setStroke()
        shape.stroke()
      }
    }
    let foreground =
      (textColor
      ?? ((style == .primary && isEnabled)
        ? chromeBackground : selected ? appAccent : chromeText))
      .withAlphaComponent(isEnabled ? 1 : 0.38)
    if let swatch {
      let ring = NSBezierPath(
        ovalIn: CGRect(x: area.midX - 9, y: area.midY - 9, width: 18, height: 18))
      (selected ? appAccent : chromeMuted.withAlphaComponent(0.32)).setStroke()
      ring.lineWidth = selected ? 1.6 : 0.9
      ring.stroke()
      let dot = NSBezierPath(ovalIn: ring.bounds.insetBy(dx: 3, dy: 3))
      (swatch.blended(withFraction: 0.16, of: .white) ?? swatch).setFill()
      dot.fill()
      return
    }
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: regularFont, .foregroundColor: foreground,
    ]
    let titleSize = (caption as NSString).size(withAttributes: titleAttributes)
    let iconWidth: CGFloat = symbol == nil ? 0 : (caption.isEmpty ? 14 : 20)
    let badgeWidth: CGFloat = shortcut == nil ? 0 : 21
    var x = max(5, (bounds.width - titleSize.width - iconWidth - badgeWidth) / 2)
    if let symbol,
      let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        ?? fallbackSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) })?
        .withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(
            .init(paletteColors: [foreground])))
    {
      let size: CGFloat = 14
      image.draw(in: CGRect(x: x, y: bounds.midY - size/2, width: size, height: size))
      x += iconWidth
    }
    if !caption.isEmpty {
      (caption as NSString).draw(
        at: CGPoint(x: x, y: (bounds.height - titleSize.height) / 2),
        withAttributes: titleAttributes)
    }
    if let shortcut {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: keyFont, .foregroundColor: selected ? appAccent : chromeMuted,
      ]
      let keySize = (shortcut as NSString).size(withAttributes: attrs)
      let inset = x + titleSize.width + 5
      let tag = NSBezierPath(
        roundedRect: CGRect(x: inset, y: bounds.midY - 7, width: 14, height: 14), xRadius: 3,
        yRadius: 3)
      chromeBorder.withAlphaComponent(0.9).setFill()
      tag.fill()
      (shortcut as NSString).draw(
        at: CGPoint(x: inset + (14 - keySize.width) / 2, y: bounds.midY - keySize.height / 2),
        withAttributes: attrs)
    }
  }
}

func chromeLabel(
  _ value: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
  color: NSColor = chromeText
) -> NSTextField {
  let label = NSTextField(labelWithString: value)
  label.font = NSFont.systemFont(ofSize: size, weight: weight)
  label.textColor = color
  return label
}

func chromeStack(_ views: [NSView], spacing: CGFloat = 6, horizontal: Bool = true) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = horizontal ? .horizontal : .vertical
  stack.alignment = horizontal ? .centerY : .leading
  stack.spacing = spacing
  stack.detachesHiddenViews = true
  stack.translatesAutoresizingMaskIntoConstraints = false
  return stack
}

func separator() -> NSView {
  let view = Surface(chromeBorder)
  view.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    view.heightAnchor.constraint(equalToConstant: 17),
    view.widthAnchor.constraint(equalToConstant: 1),
  ])
  return view
}

final class NotebookGlyph: NSView {
  let size: CGFloat
  init(size: CGFloat) {
    self.size = size
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { nil }
  override var intrinsicContentSize: NSSize { CGSize(width: size, height: size) }
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    Self.drawMark(in: bounds, context: context)
  }

  static func drawMark(in frame: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: frame.minX, y: frame.minY)
    context.scaleBy(x: frame.width / 100, y: frame.height / 100)
    let rect = CGRect(x: 3, y: 3, width: 94, height: 94)
    let rounded = CGPath(roundedRect: rect, cornerWidth: 21, cornerHeight: 21, transform: nil)
    context.addPath(rounded)
    context.clip()
    context.setFillColor(CGColor(red: 0.13, green: 0.25, blue: 0.28, alpha: 1))
    context.fill(rect)
    context.setLineWidth(0.7)
    context.setStrokeColor(CGColor(red: 0.34, green: 0.60, blue: 0.58, alpha: 0.43))
    for position in stride(from: 10, to: 100, by: 10) {
      let p = CGFloat(position)
      context.move(to: CGPoint(x: 0, y: p))
      context.addLine(to: CGPoint(x: 100, y: p))
      context.move(to: CGPoint(x: p, y: 0))
      context.addLine(to: CGPoint(x: p, y: 100))
    }
    context.strokePath()
    context.setStrokeColor(CGColor(red: 0.91, green: 0.49, blue: 0.50, alpha: 0.64))
    context.setLineWidth(1.2)
    context.move(to: CGPoint(x: 27, y: 0))
    context.addLine(to: CGPoint(x: 27, y: 100))
    context.strokePath()
    context.setStrokeColor(CGColor(red: 0.46, green: 0.85, blue: 0.76, alpha: 1))
    context.setLineWidth(5.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 17, y: 38))
    context.addCurve(
      to: CGPoint(x: 33, y: 39), control1: CGPoint(x: 22, y: 32), control2: CGPoint(x: 27, y: 33))
    context.addLine(to: CGPoint(x: 40, y: 47))
    context.addLine(to: CGPoint(x: 49, y: 24))
    context.addLine(to: CGPoint(x: 61, y: 71))
    context.addLine(to: CGPoint(x: 81, y: 71))
    context.strokePath()
    context.restoreGState()
  }
}
