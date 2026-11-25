import AppKit

final class PenPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  private var connection = InputDevice.connected()
  var device: InputDevice { connection.profile }
  var deviceDescription: String {
    connection.name.map { $0 + " · Detected" } ?? "Ready for pen or mouse"
  }
  func detectDevice(vendor: Int? = nil) { connection = InputDevice.connected(vendor: vendor) }
  private func deviceKey(_ key: String) -> String { "Device." + device.rawValue + "." + key }
  private func deviceValue(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
    let legacy = device == .wacom ? value(key, fallback: fallback, range: range) : fallback
    return value(deviceKey(key), fallback: legacy, range: range)
  }
  private func value(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
    guard let number = defaults.object(forKey: key) as? Double, number.isFinite else {
      return fallback
    }
    return min(range.upperBound, max(range.lowerBound, number))
  }

  var smoothing: Double {
    get { deviceValue("Smoothing", fallback: device == .mouse ? 0.65 : 0.48, range: 0...1) }
    set { defaults.set(newValue, forKey: deviceKey("Smoothing")) }
  }
  static let majors = [
    "None", "Chemistry", "Physics", "Medicine", "Mathematics", "Electrical Engineering",
    "Computer Science", "Mechanical Engineering",
  ]
  func toolAppearance(_ tool: NoteTool) -> (name: String, symbol: String) {
    switch tool {
    case .brush:
      return (nib, nib == "Brush" ? "paintbrush.pointed" : nib == "Fineliner" ? "pencil.line" : "pencil.tip")
    case .selector:
      return (selectionMode.rawValue, [.tap: "cursorarrow", .box: "rectangle.dashed", .lasso: "lasso"][selectionMode]!)
    case .eraser:
      return (eraseMode.rawValue, [.regular: "eraser", .stroke: "eraser.fill", .box: "square.dashed", .lasso: "lasso"][eraseMode]!)
    case .text:
      if code { return ("Code", "chevron.left.forwardslash.chevron.right") }
      return ("Text", [.natural: "textformat", .left: "text.alignleft", .center: "text.aligncenter", .right: "text.alignright"][textAlignment]!)
    case .marker: return ("Highlighter", "highlighter")
    case .shapes:
      return (shape.rawValue, [.line: "line.diagonal", .arrow: "arrow.up.right", .rectangle: "rectangle", .ellipse: "oval"][shape]!)
    case .table: return (tableHeader ? "Table with header" : "Table", tableHeader ? "rectangle.topthird.inset.filled" : "tablecells")
    }
  }

  func illustration(_ tool: NoteTool) -> String {
    switch tool {
    case .brush: return nib.lowercased()
    case .selector: return [.tap: "tap", .box: "box-select", .lasso: "lasso"][selectionMode]!
    case .eraser: return [.regular: "regular", .stroke: "stroke", .box: "region-erase", .lasso: "lasso-erase"][eraseMode]!
    case .text: return code ? "code" : [.natural: "text", .left: "left", .center: "center", .right: "right"][textAlignment]!
    case .marker: return "marker"
    case .shapes: return [.line: "line", .arrow: "arrow", .rectangle: "box", .ellipse: "oval"][shape]!
    case .table: return tableHeader ? "table-header" : "table"
    }
  }
  var theme: NotebookTheme {
    get {
      defaults.string(forKey: "NotebookAppearance").flatMap(NotebookTheme.init(rawValue:))
        ?? (defaults.bool(forKey: "CartoonAppearance") ? .cartoon : .standard)
    }
    set { defaults.set(newValue.rawValue, forKey: "NotebookAppearance") }
  }
  var cartoonTheme: Bool {
    get { theme == .cartoon }
    set { theme = newValue ? .cartoon : .standard }
  }
  var major: String {
    get {
      defaults.string(forKey: "StudyMajor").flatMap { Self.majors.contains($0) ? $0 : nil }
        ?? "None"
    }
    set { if Self.majors.contains(newValue) { defaults.set(newValue, forKey: "StudyMajor") } }
  }
  var nib: String {
    get { defaults.string(forKey: deviceKey("Nib")) ?? "Brush" }
    set { defaults.set(newValue, forKey: deviceKey("Nib")) }
  }
  var usePressure: Bool {
    get { defaults.object(forKey: deviceKey("UsePressure")) as? Bool ?? true }
    set { defaults.set(newValue, forKey: deviceKey("UsePressure")) }
  }
  func response(to force: Double) -> Double {
    guard device.pressure, usePressure, nib != "Fineliner" else { return 1 }
    let level = pow(min(1, max(0, force)), pressure)
    return nib == "Pen" ? 0.72 + 0.55 * level : 0.30 + 1.30 * level
  }
  func restore(_ tool: NoteTool? = nil) {
    let scoped: [NoteTool: [String]] = [
      .brush: ["Nib", "UsePressure", "BrushWidth", "Smoothing", "Pressure"],
      .eraser: ["EraserDiameter"],
    ]
    let common: [NoteTool: [String]] = [
      .brush: ["InkColor"], .selector: ["SelectionMode", "SelectionMask", "AlignmentGuides"],
      .eraser: ["EraseMode"], .text: ["TextSize", "TextAlignment", "TextColor", "CodeBlocks"],
      .marker: ["MarkerWidth", "MarkerOpacity", "MarkerColor"],
      .shapes: ["ShapeWidth", "Shape", "ConstrainShape"],
      .table: ["TableRows", "TableColumns", "TableHeader", "TableWidth", "TableHeight"],
    ]
    let profiles = tool == nil ? InputDevice.allCases : [device]
    for t in tool.map({ [$0] }) ?? NoteTool.allCases {
      for k in common[t] ?? [] { defaults.removeObject(forKey: k) }
      for k in scoped[t] ?? [] {
        if profiles.contains(.wacom) { defaults.removeObject(forKey: k) }
        for profile in profiles {
          defaults.removeObject(forKey: "Device." + profile.rawValue + "." + k)
        }
      }
    }
    if tool == nil {
      for profile in profiles {
        defaults.removeObject(forKey: "Device." + profile.rawValue + ".PenScrollSpeed")
      }
      defaults.removeObject(forKey: "PenScrollSpeed")
      defaults.removeObject(forKey: "PaletteVisible")
      defaults.removeObject(forKey: "StudyMajor")
      defaults.removeObject(forKey: "CartoonAppearance")
      defaults.removeObject(forKey: "NotebookAppearance")
    }
  }
  var pressure: Double {
    get { deviceValue("Pressure", fallback: 1, range: 0.50...2) }
    set { defaults.set(newValue, forKey: deviceKey("Pressure")) }
  }
  var width: Double {
    get { deviceValue("BrushWidth", fallback: 2.0, range: 0.7...6) }
    set { defaults.set(newValue, forKey: deviceKey("BrushWidth")) }
  }
  var scrollSpeed: Double {
    get { deviceValue("PenScrollSpeed", fallback: 0.30, range: 0.12...0.65) }
    set { defaults.set(newValue, forKey: deviceKey("PenScrollSpeed")) }
  }
  var colorIndex: Int {
    get { min(InkColor.colors.count - 1, max(0, defaults.integer(forKey: "InkColor"))) }
    set { defaults.set(newValue, forKey: "InkColor") }
  }
  var textSize: Double {
    get { value("TextSize", fallback: 14, range: 8...36) }
    set { defaults.set(newValue, forKey: "TextSize") }
  }
  var eraserDiameter: Double {
    get { deviceValue("EraserDiameter", fallback: 18, range: 6...36) }
    set { defaults.set(newValue, forKey: deviceKey("EraserDiameter")) }
  }
  var textAlignment: TypeAlignment {
    get { TypeAlignment(rawValue: defaults.string(forKey: "TextAlignment") ?? "") ?? .natural }
    set { defaults.set(newValue.rawValue, forKey: "TextAlignment") }
  }
  var textColor: Int {
    get { min(InkColor.colors.count - 1, max(0, defaults.integer(forKey: "TextColor"))) }
    set { defaults.set(newValue, forKey: "TextColor") }
  }
  var eraseMode: EraseMode {
    get { EraseMode(rawValue: defaults.string(forKey: "EraseMode") ?? "") ?? .stroke }
    set { defaults.set(newValue.rawValue, forKey: "EraseMode") }
  }
  var selectionMask: Int {
    get { defaults.object(forKey: "SelectionMask") as? Int ?? 7 }
    set { defaults.set(newValue, forKey: "SelectionMask") }
  }
  var selectionMode: SelectMode {
    get { SelectMode(rawValue: defaults.string(forKey: "SelectionMode") ?? "") ?? .tap }
    set { defaults.set(newValue.rawValue, forKey: "SelectionMode") }
  }
  var markerWidth: Double {
    get { value("MarkerWidth", fallback: 11, range: 3...24) }
    set { defaults.set(newValue, forKey: "MarkerWidth") }
  }
  var markerOpacity: Double {
    get { value("MarkerOpacity", fallback: 0.38, range: 0.12...0.75) }
    set { defaults.set(newValue, forKey: "MarkerOpacity") }
  }
  var markerIndex: Int {
    get { min(4, max(0, defaults.integer(forKey: "MarkerColor"))) }
    set { defaults.set(newValue, forKey: "MarkerColor") }
  }
  var shapeWidth: Double {
    get { value("ShapeWidth", fallback: 2, range: 0.7...6) }
    set { defaults.set(newValue, forKey: "ShapeWidth") }
  }
  var shape: ShapeKind {
    get { ShapeKind(rawValue: defaults.string(forKey: "Shape") ?? "") ?? .line }
    set { defaults.set(newValue.rawValue, forKey: "Shape") }
  }
  var constrain: Bool {
    get { defaults.bool(forKey: "ConstrainShape") }
    set { defaults.set(newValue, forKey: "ConstrainShape") }
  }
  var code: Bool {
    get { defaults.bool(forKey: "CodeBlocks") }
    set { defaults.set(newValue, forKey: "CodeBlocks") }
  }
  var guides: Bool {
    get { defaults.object(forKey: "AlignmentGuides") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "AlignmentGuides") }
  }
  private var tableHeader: Bool { defaults.object(forKey: "TableHeader") as? Bool ?? true }
  var grid: TableGrid {
    get {
      TableGrid(
        rows: defaults.object(forKey: "TableRows") as? Int ?? 3,
        columns: defaults.object(forKey: "TableColumns") as? Int ?? 3,
        header: tableHeader)
    }
    set {
      defaults.set(newValue.rows, forKey: "TableRows")
      defaults.set(newValue.columns, forKey: "TableColumns")
      defaults.set(newValue.header, forKey: "TableHeader")
    }
  }
  var tableSize: CGSize {
    get {
      CGSize(
        width: value("TableWidth", fallback: 240, range: 36...paperSize.width),
        height: value("TableHeight", fallback: 84, range: 18...paperSize.height))
    }
    set {
      defaults.set(newValue.width, forKey: "TableWidth")
      defaults.set(newValue.height, forKey: "TableHeight")
    }
  }
  var paletteVisible: Bool {
    get { defaults.object(forKey: "PaletteVisible") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "PaletteVisible") }
  }
}

enum NoteTool: String, CaseIterable { case brush, selector, eraser, text, marker, shapes, table }
enum SelectMode: String, CaseIterable {
  case tap = "Tap"
  case box = "Rectangle"
  case lasso = "Lasso"
}

final class NoteCanvas: NSView, NSTextViewDelegate {
  static let objectsType = NSPasteboard.PasteboardType("app.gridnote.objects")
  let preferences: PenPreferences
  private let clipboard: NSPasteboard
  private let textHistory = UndoManager()
  let history = UndoManager()
  var active = false
  var notebook = Notebook()
  var renderer = PaperRenderer()
  var didEdit: (() -> Void)?
  var positionDidChange: (() -> Void)?
  var toolDidChange: (() -> Void)?
  var reportError: ((String, Error) -> Void)?
  var pageCount = 2
  var scale: CGFloat { frame.width / paperSize.width }
  var selectMode: SelectMode {
    get { preferences.selectionMode }
    set { preferences.selectionMode = newValue }
  }
  private var erasingRegion = false
  private var marqueeMode: SelectMode {
    erasingRegion ? (preferences.eraseMode == .box ? .box : .lasso) : selectMode
  }
  private func included(_ object: NoteObject) -> Bool {
    let flag: Int
    switch object.content {
    case .ink: flag = 1
    case .text: flag = 2
    case .image: flag = 4
    }
    return preferences.selectionMask & flag != 0
  }
  func applySelectionFilters() {
    setSelection(selection.intersection(notebook.objects.filter(included).map(\.id)))
  }

  var tool: NoteTool = .brush { didSet { refreshTool() } }
  var buttons = TabletButtons()
  var tabletEraser = false { didSet { if tabletEraser != oldValue { refreshTool() } } }
  var panTimer: Timer?
  var pendingPan: CGFloat = 0
  var lastPanLocation: CGPoint?
  var lastTabletInput: (location: CGPoint, timestamp: TimeInterval, pressure: Float, tip: Bool)?
  var spacePan = false
  var translatedSideClick = false
  var ignoredTip = false
  var tipIsDown = false
  var penInProximity = false
  var penTraceLast = ""
  var penTraceCount = 0
  var lastPenPanMotion = TimeInterval.zero
  var scrollBy: ((CGFloat) -> Void)?
  var pinch: ((CGFloat, CGPoint) -> Void)?

  private var selection = Set<UUID>()
  private var selectedBounds: CGRect? {
    let bounds = notebook.objects.lazy.filter { self.selection.contains($0.id) }.reduce(CGRect.null)
    { $0.union($1.frame) }
    return bounds.isNull ? nil : bounds
  }
  private var ink: [InkPoint] = []
  private var inkColor: InkColor?
  private var inkSmoothing: CGFloat = 0
  private var inkTimes: [TimeInterval] = []
  private var draftID = UUID()
  private var lastCheckpoint: TimeInterval = 0
  private var liveSegments: [(CGRect, CGPath)] = []
  private var previewStart = 0
  private var inkBounds = CGRect.null
  private var lastErase: CGPoint?
  private var gestureOrigin: CGPoint?
  private var originalObjects: [NoteObject]?
  private var transformBounds: CGRect?
  private var transformMode: TransformMode?
  private var marquee: [CGPoint] = []
  private var originalSelection = Set<UUID>()
  private var editing: TextEdit?
  private var cellEdit: (object: NoteObject, index: Int)?
  private var drawingBlock = false
  private var blockPreview: NoteObject?
  private var guideTargets: [CGRect] = []
  private var activeGuides: [AlignGuide] = []
  private var measurement: (label: NSAttributedString, frame: CGRect)?
  private var codeButton: NSButton?
  var studyProblems: [StudyProblem] = [] { didSet { needsDisplay = true } }
  var onStudyPick: ((StudyProblem) -> Void)?
  var selectedObject: NoteObject? {
    selection.count == 1 ? notebook.objects.first { selection.contains($0.id) } : nil
  }

  private enum TransformMode {
    case move
    case resize(anchor: CGPoint)
  }
  private struct TextEdit {
    var object: NoteObject
    let view: NSTextView
    let existing: Bool
  }

  var editor: NSTextView? { editing?.view }
  var effectiveTool: NoteTool { buttons.eraserArmed || tabletEraser ? .eraser : tool }
  var hasSelection: Bool { !selection.isEmpty }
  private var currentColor: InkColor { InkColor.colors[preferences.colorIndex].1 }
  private var selectionPadding: CGFloat { 4 / max(0.1, scale) }

  init(preferences: PenPreferences, clipboard: NSPasteboard = .general) {
    self.clipboard = clipboard
    self.preferences = preferences
    super.init(frame: CGRect(origin: .zero, size: paperSize))
    history.groupsByEvent = false
    history.levelsOfUndo = 100
    registerForDraggedTypes([.fileURL, .png, .tiff])
    setAccessibilityRole(.group)
    setAccessibilityLabel("Notebook paper")
  }

  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var undoManager: UndoManager? { history }

  func load(_ value: Notebook) {
    resetInputForFocus()
    finishText()
    active = true
    studyProblems = []
    notebook = value
    renderer = PaperRenderer(pdfData: value.sourcePDF)
    history.removeAllActions()
    selection.removeAll()
    pageCount = max(2, value.usedPages + 1)
    tool = .brush
    needsDisplay = true
  }

  func sizing(width: CGFloat, pages: Int) {
    pageCount = pages
    let unscaled = CGSize(width: paperSize.width, height: paperSize.height * CGFloat(pages))
    let newSize = CGSize(width: width, height: unscaled.height * width / paperSize.width)
    guard frame.size != newSize else { return }
    setFrameSize(newSize)
    setBoundsSize(unscaled)
    updateCodeButton()
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard active, !visibleRect.isEmpty else { return }
    let cursor: NSCursor
    if buttons.scrolling {
      cursor = .closedHand
    } else {
      switch effectiveTool {
      case .brush, .marker: cursor = Self.penCursor
      case .eraser: cursor = Self.createCursor(diameter: preferences.eraserDiameter, ring: true)
      case .shapes, .table: cursor = .crosshair
      case .selector: cursor = .arrow
      case .text: cursor = .iBeam
      }
    }
    addCursorRect(visibleRect, cursor: cursor)
  }

  private static let penCursor = createCursor(diameter: 4, ring: false)

  private static func createCursor(diameter: CGFloat, ring: Bool) -> NSCursor {
    let side = diameter + 4
    let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
      let ellipse = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: diameter, height: diameter))
      NSColor.white.setStroke()
      ellipse.lineWidth = ring ? 2.6 : 1.6
      ellipse.stroke()
      NSColor(srgbRed: 0.10, green: 0.14, blue: 0.16, alpha: 0.9).set()
      if ring {
        ellipse.lineWidth = 1.15
        ellipse.stroke()
      } else {
        ellipse.fill()
      }
      return true
    }
    return NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
  }

  func refreshTool() {
    positionDidChange?()
    window?.invalidateCursorRects(for: self)
    updateCodeButton()
    toolDidChange?()
    if let frame = selectedBounds {
      invalidate(frame, padding: selectionPadding + 8 / max(0.1, scale))
    }
  }

  func chooseTool(_ next: NoteTool) {
    finishText()
    finishGesture()
    buttons.eraserArmed = false
    buttons.eraserContact = false
    studyProblems = []
    tool = next
    window?.makeFirstResponder(self)
  }

  private func invalidate(_ rect: CGRect, padding: CGFloat = 4) {
    if !rect.isNull { setNeedsDisplay(rect.insetBy(dx: -padding, dy: -padding)) }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard active, let context = NSGraphicsContext.current?.cgContext else { return }
    let first = max(0, Int(floor(dirtyRect.minY / paperSize.height)))
    let last = min(pageCount - 1, Int(floor(dirtyRect.maxY / paperSize.height)))
    if first <= last {
      for page in first...last {
        renderer.draw(
          page: page, design: notebook.paper(on: page), sourceIndex: notebook.sourceIndex(on: page),
          originalScale: notebook.originalPDFScale == true, context: context)
      }
    }
    for object in notebook.objects
    where (object.id != editing?.object.id || cellEdit != nil) && object.frame.intersects(dirtyRect)
    {
      renderer.draw(object, context: context)
    }
    if let inkColor, inkBounds.insetBy(dx: -1, dy: -1).intersects(dirtyRect) {
      context.saveGState()
      if tool == .marker {
        context.setAlpha(preferences.markerOpacity)
        context.setBlendMode(.multiply)
      }
      defer { context.restoreGState() }
      func section(_ start: Int, _ end: Int) -> CGPath {
        renderer.outline(
          smoothedInk(
            Array(ink[start...end]), amount: inkSmoothing, times: Array(inkTimes[start...end])))
      }
      while ink.count - previewStart > 100 {
        let end = previewStart + 96
        let path = section(previewStart, end)
        liveSegments.append((path.boundingBoxOfPath, path))
        previewStart = end
      }
      context.setFillColor(inkColor.cg)
      for (bounds, path) in liveSegments where bounds.intersects(dirtyRect) {
        context.addPath(path)
      }
      if ink.count > previewStart { context.addPath(section(previewStart, ink.count - 1)) }
      context.fillPath()
    }
    if first <= last {
      context.setStrokeColor(CGColor(red: 0.53, green: 0.59, blue: 0.63, alpha: 1))
      context.setLineWidth(1.15 / max(0.1, scale))
      for page in first...last where page > 0 {
        let y = CGFloat(page) * paperSize.height
        context.move(to: CGPoint(x: 0, y: y))
        context.addLine(to: CGPoint(x: paperSize.width, y: y))
      }
      context.strokePath()
    }
    if let blockPreview { renderer.draw(blockPreview, context: context) }
    for problem in studyProblems where problem.frame.intersects(dirtyRect) {
      let f = problem.frame.insetBy(dx: -2, dy: -1)
      context.setFillColor(
        NSColor.systemYellow.withAlphaComponent(problem.origin == nil ? 0.22 : 0.08).cgColor)
      context.fill(f)
      context.setStrokeColor(NSColor.systemOrange.cgColor)
      context.setLineWidth(1 / scale)
      context.stroke(f)
    }
    drawSelection(context)
    context.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.85).cgColor)
    context.setLineWidth(1 / max(0.1, scale))
    for guide in activeGuides {
      context.move(to: guide.a)
      context.addLine(to: guide.b)
    }
    context.strokePath()
    if let measurement {
      NSColor(srgbRed: 0.15, green: 0.21, blue: 0.21, alpha: 1).setFill()
      measurement.frame.fill()
      measurement.label.draw(
        at: CGPoint(x: measurement.frame.minX + 6 / scale, y: measurement.frame.minY + 3 / scale))
    }
  }

  private func drawSelection(_ context: CGContext) {
    let pixel = 1 / max(0.1, scale)
    context.saveGState()
    defer { context.restoreGState() }
    let outline = NSColor(srgbRed: 0.08, green: 0.48, blue: 0.43, alpha: 1)
    context.setStrokeColor(outline.cgColor)
    context.setLineWidth(pixel)
    if [.selector, .table, .text].contains(effectiveTool),
      let bounds = selectedBounds?.insetBy(dx: -selectionPadding, dy: -selectionPadding)
    {
      context.setLineDash(phase: 0, lengths: [4 * pixel, 3 * pixel])
      context.stroke(bounds)
      context.setLineDash(phase: 0, lengths: [])
      context.setFillColor(.white)
      for point in corners(of: bounds) {
        let rect = CGRect(
          x: point.x - 3 * pixel, y: point.y - 3 * pixel, width: 6 * pixel, height: 6 * pixel)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
      }
    }
    guard let start = marquee.first, let last = marquee.last, marquee.count >= 2 else { return }
    context.setFillColor(outline.withAlphaComponent(0.1).cgColor)
    context.setLineDash(phase: 0, lengths: [4 * pixel, 2 * pixel])
    if marqueeMode == .box {
      context.addRect(rectBetween(start, last))
    } else {
      context.move(to: start)
      context.addLines(between: marquee)
      context.closePath()
    }
    context.drawPath(using: .eoFillStroke)
  }

  private func corners(of rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
    ]
  }

  private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  private func rectAround(_ points: [CGPoint]) -> CGRect {
    points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
  }

  private func sample(_ event: NSEvent, point: CGPoint, usingLastPressure: Bool = false) -> InkPoint
  {
    let tabletPressure: Float?
    if usingLastPressure || !preferences.device.pressure {
      tabletPressure = nil
    } else if event.isTabletSample {
      tabletPressure = event.pressure
    } else if let last = lastTabletInput, last.tip, event.timestamp - last.timestamp < 0.15,
      event.locationInWindow.distance(to: last.location) < 20
    {
      tabletPressure = last.pressure
    } else {
      tabletPressure = nil
    }
    var radius = preferences.width * 0.5
    if let tabletPressure {
      radius *= preferences.response(to: Double(tabletPressure))
      if let last = ink.last { radius = radius * 0.68 + last.radius * 0.32 }
    } else if usingLastPressure, let last = ink.last {
      radius = last.radius
    }
    if tool == .marker { radius = preferences.markerWidth / 2 }
    let clamped = CGPoint(
      x: min(paperSize.width - radius, max(radius, point.x)),
      y: min(bounds.height - radius, max(radius, point.y)))
    return InkPoint(position: clamped, radius: radius)
  }

  func appendInk(_ event: NSEvent, location: CGPoint, isLift: Bool = false) {
    guard inkColor != nil else { return }
    let point = sample(event, point: location, usingLastPressure: isLift)
    if let previous = ink.last, point.position.distance(to: previous.position) < 0.12 {
      if ink.count == 1, abs(point.radius - previous.radius) > 0.06 {
        ink[0].radius = max(previous.radius, point.radius)
        inkBounds = inkBounds.union(ink[0].bounds)
        invalidate(inkBounds)
      }
      return
    }
    ink.append(point)
    inkTimes.append(event.timestamp)
    inkBounds = inkBounds.union(point.bounds)
    let tail = ink.suffix(5).reduce(CGRect.null) { $0.union($1.bounds) }
    invalidate(ink.count < 8 ? inkBounds : tail)
    if event.timestamp - lastCheckpoint > 0.8, ink.count > 2 {
      lastCheckpoint = event.timestamp
      notebook.revision += 1
      didEdit?()
    }
  }

  override func mouseDown(with event: NSEvent) {
    startContact(event, at: convert(event.locationInWindow, from: nil))
  }

  func startContact(_ event: NSEvent, at point: CGPoint) {
    guard active, !tipIsDown, !buttons.scrolling, !ignoredTip else { return }
    tipIsDown = true
    window?.makeFirstResponder(self)
    finishText()
    if let problem = studyProblems.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    ) {
      onStudyPick?(problem)
      return
    }
    gestureOrigin = point
    switch effectiveTool {
    case .brush, .marker:
      liveSegments.removeAll(keepingCapacity: true)
      previewStart = 0
      draftID = UUID()
      lastCheckpoint = event.timestamp
      inkColor = tool == .marker ? markerColors[preferences.markerIndex].1 : currentColor
      inkSmoothing = preferences.smoothing
      appendInk(event, location: point)
    case .eraser:
      if !buttons.eraserArmed, !tabletEraser, [.box, .lasso].contains(preferences.eraseMode) {
        erasingRegion = true
        marquee = [point]
      } else {
        beginArmedErase(at: point)
      }
    case .selector:
      startSelection(at: point, event: event)
    case .text:
      gestureOrigin = nil
      let existing = object(at: point).flatMap { o -> NoteObject? in
        if case .text = o.content, o.table == nil { return o }
        return nil
      }
      startText(at: point, existing: existing)
    case .table, .shapes:
      if effectiveTool == .table, let o = object(at: point), o.table != nil {
        setSelection([o.id])
        beginCell(at: point, object: o)
      } else {
        drawingBlock = true
        updateBlock(to: point, shift: event.modifierFlags.contains(.shift))
      }
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard active, tipIsDown, !buttons.scrolling, !ignoredTip else { return }
    updateGesture(with: event)
  }

  func updateGesture(with event: NSEvent, location: CGPoint? = nil) {
    let point = location ?? convert(event.locationInWindow, from: nil)
    if drawingBlock {
      updateBlock(to: point, shift: event.modifierFlags.contains(.shift))
    } else if inkColor != nil {
      appendInk(event, location: point)
    } else if lastErase != nil {
      erase(to: point)
    } else if transformMode != nil {
      transformSelection(to: point)
    } else if !marquee.isEmpty {
      updateMarquee(to: point)
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard active, tipIsDown || ignoredTip else { return }
    tipIsDown = false
    if !buttons.scrolling, !ignoredTip {
      let point = convert(event.locationInWindow, from: nil)
      if drawingBlock {
        updateBlock(to: point, shift: event.modifierFlags.contains(.shift))
      } else if inkColor != nil {
        appendInk(event, location: point, isLift: true)
      } else if lastErase != nil {
        erase(to: point)
      } else if transformMode != nil {
        transformSelection(to: point)
      } else if !marquee.isEmpty {
        endSelection(at: point)
      }
      finishGesture()
    }
    ignoredTip = false
    returnToBrushAfterLift()
  }

  func returnToBrushAfterLift() {
    if buttons.eraserArmed && buttons.eraserContact {
      buttons.eraserContact = false
      buttons.eraserArmed = false
      tool = .brush
    }
  }

  func finishGesture() {
    if drawingBlock {
      drawingBlock = false
      if let o = blockPreview {
        blockPreview = nil
        didChange(
          from: notebook.objects, to: notebook.objects + [o],
          name: o.table == nil ? "Draw Shape" : "Insert Table")
        if o.table != nil {
          tool = .selector
          setSelection([o.id])
        }
      }
    } else if let object = draftInk() {
      didChange(
        from: notebook.objects, to: notebook.objects + [object], name: "Brush Stroke",
        redraw: object.frame)
    } else if let originalObjects {
      didChange(
        from: originalObjects, to: notebook.objects,
        name: lastErase == nil ? "Transform Selection" : "Erase", redraw: .null)
    }
    ink.removeAll(keepingCapacity: true)
    inkTimes.removeAll(keepingCapacity: true)
    inkColor = nil
    liveSegments.removeAll(keepingCapacity: true)
    previewStart = 0
    inkBounds = .null
    lastErase = nil
    originalObjects = nil
    transformBounds = nil
    updateGuides([])
    if let measurement { invalidate(measurement.frame); self.measurement = nil }
    guideTargets = []
    transformMode = nil
    gestureOrigin = nil
    invalidate(rectAround(marquee), padding: selectionPadding + 8)
    marquee.removeAll(keepingCapacity: true)
    erasingRegion = false
  }

  func beginArmedErase(at point: CGPoint) {
    if buttons.eraserArmed { buttons.eraserContact = true }
    originalObjects = notebook.objects
    erase(to: point)
  }

  private func erase(to point: CGPoint) {
    let previous = lastErase ?? point
    if lastErase == point { return }
    lastErase = point
    let radius = preferences.eraserDiameter * 0.5 / max(scale, 0.1)
    let touch = rectBetween(previous, point).insetBy(dx: -radius, dy: -radius)
    var redraw = CGRect.null
    if preferences.eraseMode == .regular {
      notebook.objects = notebook.objects.flatMap { object -> [NoteObject] in
        guard object.frame.intersects(touch),
          let fragments = object.erasingPart(from: previous, to: point, radius: radius)
        else { return [object] }
        redraw = redraw.union(object.frame)
        return fragments
      }
      invalidate(redraw)
      return
    }
    notebook.objects.removeAll { object in
      guard case .ink(let points, _) = object.content, object.frame.intersects(touch),
        let first = points.first
      else { return false }
      let hit: Bool
      if points.count == 1 {
        hit = distance(first.position, toSegmentFrom: previous, to: point) <= radius + first.radius
      } else {
        hit = zip(points, points.dropFirst()).contains { a, b in
          segmentsTouch(
            previous, point, a.position, b.position, radius: radius + max(a.radius, b.radius))
        }
      }
      if hit { redraw = redraw.union(object.frame) }
      return hit
    }
    invalidate(redraw)
  }

  private func startSelection(at point: CGPoint, event: NSEvent) {
    let shift = event.modifierFlags.contains(.shift)
    if !shift, let bounds = selectedBounds {
      let handles = corners(of: bounds.insetBy(dx: -selectionPadding, dy: -selectionPadding))
      if let index = handles.firstIndex(where: { $0.distance(to: point) <= 8 / max(0.1, scale) }) {
        startTransform(bounds: bounds, mode: .resize(anchor: corners(of: bounds)[(index + 2) % 4]))
        return
      }
      if bounds.insetBy(dx: -selectionPadding, dy: -selectionPadding).contains(point) {
        if event.isPointerEvent, event.clickCount >= 2, let hit = object(at: point),
          case .text = hit.content
        {
          startText(at: point, existing: hit)
        } else {
          startTransform(bounds: bounds, mode: .move)
        }
        return
      }
    }
    if !shift, selectMode == .tap, let hit = object(at: point) {
      setSelection([hit.id])
      if event.isPointerEvent, event.clickCount >= 2, case .text = hit.content {
        startText(at: point, existing: hit)
      } else {
        startTransform(bounds: hit.frame, mode: .move)
      }
      return
    }
    originalSelection = shift ? selection : []
    marquee = [point]
  }

  private func object(at point: CGPoint) -> NoteObject? {
    notebook.objects.reversed().first {
      included($0) && $0.contains(point, tolerance: 3.5 / max(0.1, scale))
    }
  }

  private func startTransform(bounds: CGRect, mode: TransformMode) {
    originalObjects = notebook.objects
    transformBounds = bounds
    transformMode = mode
    guideTargets = notebook.objects.compactMap {
      !selection.contains($0.id) && visibleRect.intersects($0.frame) ? $0.frame : nil
    }
  }

  private func transformSelection(to point: CGPoint) {
    guard let before = originalObjects, let mode = transformMode, let bounds = transformBounds,
      let start = gestureOrigin
    else { return }
    let oldBounds = selectedBounds ?? bounds
    let anchor: CGPoint
    let multiplier: CGFloat
    let offset: CGPoint
    switch mode {
    case .move:
      anchor = .zero
      multiplier = 1
      let lowerX = min(0, paperSize.width - bounds.width) - bounds.minX
      let upperX = max(0, paperSize.width - bounds.width) - bounds.minX
      let dx = min(upperX, max(lowerX, point.x - start.x))
      let dy = max(-bounds.minY, min(self.bounds.maxY - bounds.maxY, point.y - start.y))
      var move = CGPoint(x: dx, y: dy)
      if preferences.guides && (abs(dx) + abs(dy)) * scale > 2 {
        let (snap, guides) = alignment(
          for: bounds.offsetBy(dx: dx, dy: dy), near: guideTargets, tolerance: 4 / scale)
        move.x = min(upperX, max(lowerX, dx + snap.x))
        move.y = min(self.bounds.maxY - bounds.maxY, max(-bounds.minY, dy + snap.y))
        updateGuides(guides)
      } else {
        updateGuides([])
      }
      offset = move
    case .resize(let fixed):
      if selection.count == 1,
        let i = before.firstIndex(where: { selection.contains($0.id) && $0.table != nil })
      {
        let raw = point - start
        var f = before[i].frame
        let left = fixed.x >= f.maxX
        let top = fixed.y >= f.maxY
        let width = min(
          left ? fixed.x : paperSize.width - fixed.x, max(36, f.width + (left ? -raw.x : raw.x)))
        let height = min(paperSize.height, max(18, f.height + (top ? -raw.y : raw.y)))
        f = CGRect(
          x: left ? fixed.x - width : fixed.x, y: top ? max(0, fixed.y - height) : fixed.y,
          width: width, height: height)
        notebook.objects = before
        notebook.objects[i].frame = f
        notebook.objects[i].layoutFrame = nil
        measure(f, at: point, fixed: fixed)
        invalidate(oldBounds.union(f), padding: selectionPadding + 8)
        return
      }
      anchor = fixed
      let initial = start - anchor
      let wanted = (point - anchor).dot(initial) / max(0.001, initial.dot(initial))
      var limit: CGFloat = 30
      if bounds.maxX > anchor.x {
        limit = min(limit, (paperSize.width - anchor.x) / (bounds.maxX - anchor.x))
      }
      if bounds.minX < anchor.x { limit = min(limit, anchor.x / (anchor.x - bounds.minX)) }
      if bounds.minY < anchor.y { limit = min(limit, anchor.y / (anchor.y - bounds.minY)) }
      if bounds.maxY > anchor.y {
        limit = min(limit, (self.bounds.maxY - anchor.y) / (bounds.maxY - anchor.y))
      }
      multiplier = max(
        0.05, min(max(1, limit), max(min(1, 5 / max(bounds.width, bounds.height)), wanted)))
      offset = .zero
    }
    notebook.objects = before.map { object in
      selection.contains(object.id)
        ? object.transformed(from: anchor, scale: multiplier, offset: offset) : object
    }
    if case .resize(let fixed) = mode, let frame = selectedBounds {
      measure(frame, at: point, fixed: fixed)
    }
    updateCodeButton()
    invalidate(oldBounds.union(selectedBounds ?? oldBounds), padding: selectionPadding + 8)
  }

  private func updateMarquee(to point: CGPoint) {
    let oldBounds = rectAround(marquee)
    switch marqueeMode {
    case .tap: break
    case .box: marquee = [marquee[0], point]
    case .lasso:
      if let last = marquee.last, last.distance(to: point) > 1.5 / max(0.1, scale) {
        marquee.append(point)
      }
    }
    updateCodeButton()
    invalidate(oldBounds.union(rectAround(marquee)), padding: selectionPadding + 8)
  }

  private func endSelection(at point: CGPoint) {
    guard let start = marquee.first else { return }
    if erasingRegion {
      updateMarquee(to: point)
      let polygon = marqueeMode == .box ? corners(of: rectBetween(start, point)) : marquee
      let bounds = rectAround(polygon)
      let next = notebook.objects.filter { object in
        guard case .ink = object.content else { return true }
        if bounds.width + bounds.height < 4 / max(0.1, scale) {
          return !object.contains(
            point, tolerance: preferences.eraserDiameter / (2 * max(0.1, scale)))
        }
        return !polygonSelects(object, polygon: polygon, bounds: bounds)
      }
      didChange(from: notebook.objects, to: next, name: "Erase Strokes in Region")
      return
    }
    if selectMode == .tap || (point.distance(to: start) < 4 / max(0.1, scale) && marquee.count < 3)
    {
      if let hit = object(at: point) {
        var ids = originalSelection
        if ids.remove(hit.id) == nil { ids.insert(hit.id) }
        setSelection(ids)
      } else {
        setSelection(originalSelection)
      }
      return
    }
    updateMarquee(to: point)
    let polygon = selectMode == .box ? corners(of: rectBetween(start, point)) : marquee
    let bounds = rectAround(polygon)
    let hits = notebook.objects.filter {
      included($0) && polygonSelects($0, polygon: polygon, bounds: bounds)
    }
    setSelection(originalSelection.union(hits.map(\.id)))
  }

  func setSelection(_ ids: Set<UUID>) {
    if let bounds = selectedBounds { invalidate(bounds, padding: selectionPadding + 8) }
    selection = ids
    updateCodeButton()
    positionDidChange?()
    toolDidChange?()
    if let bounds = selectedBounds { invalidate(bounds, padding: selectionPadding + 8) }
  }

  private func didChange(
    from previous: [NoteObject], to next: [NoteObject], name: String, redraw: CGRect? = nil
  ) {
    guard previous != next else { return }
    let group = !history.isUndoing && !history.isRedoing
    if group { history.beginUndoGrouping() }
    history.registerUndo(withTarget: self) { canvas in
      canvas.didChange(from: canvas.notebook.objects, to: previous, name: name)
      canvas.setSelection([])
    }
    history.setActionName(name)
    if group { history.endUndoGrouping() }
    studyProblems = []
    notebook.objects = next
    notebook.revision += 1
    if let redraw { invalidate(redraw) } else { needsDisplay = true }
    didEdit?()
  }

  func setPaper(_ design: PaperDesign?, on page: Int?) {
    let previous = page.flatMap { notebook.pagePaper?[$0] }
    let oldValue = page == nil ? notebook.defaultPaper : previous
    let value = page != nil && design == (notebook.defaultPaper ?? PaperDesign()) ? nil : design
    guard oldValue != value else { return }
    let group = !history.isUndoing && !history.isRedoing
    if group { history.beginUndoGrouping() }
    history.registerUndo(withTarget: self) { canvas in canvas.setPaper(oldValue, on: page) }
    history.setActionName("Change Paper")
    if group { history.endUndoGrouping() }
    if let page {
      var overrides = notebook.pagePaper ?? [:]
      overrides[page] = value
      notebook.pagePaper = overrides.isEmpty ? nil : overrides
    } else {
      notebook.defaultPaper = value
    }
    notebook.revision += 1
    needsDisplay = true
    didEdit?()
  }

  func clearAllWriting(typedOnly: Bool, page: Int? = nil) {
    finishText()
    finishGesture()
    let remaining = notebook.objects.flatMap { object -> [NoteObject] in
      guard object.table == nil, object.codeStyle == nil, object.instrument != "shape" else {
        return [object]
      }
      switch object.content {
      case .image: return [object]
      case .ink where typedOnly: return [object]
      default: return page.map { removePageWriting(from: [object], page: $0) } ?? []
      }
    }
    didChange(
      from: notebook.objects, to: remaining,
      name: typedOnly ? "Remove Typed Text" : "Clear All Writing")
    setSelection([])
  }

  func deletePage(_ page: Int) {
    guard page < notebook.usedPages else { return }
    finishText()
    finishGesture()
    arrangePages(
      Array(0..<notebook.usedPages).filter { $0 != page }.map { Optional($0) }, name: "Delete Page")
  }

  func arrangePages(_ order: [Int?], name: String) {
    finishText()
    finishGesture()
    applyPageDeletion(arrangedPages(notebook, order: order), name: name)
  }
  private func applyPageDeletion(_ next: Notebook, name: String) {
    let previous = notebook
    let group = !history.isUndoing && !history.isRedoing
    if group { history.beginUndoGrouping() }
    history.registerUndo(withTarget: self) { $0.applyPageDeletion(previous, name: name) }
    history.setActionName(name)
    if group { history.endUndoGrouping() }
    notebook = next
    notebook.revision = previous.revision + 1
    setSelection([])
    needsDisplay = true
    didEdit?()
  }

  func clearWriting(page: Int) {
    finishText()
    finishGesture()
    didChange(
      from: notebook.objects, to: removePageWriting(from: notebook.objects, page: page),
      name: "Clear Writing on This Page")
    setSelection([])
  }

  var selectionCount: Int { selection.count }
  var hasSelectedInk: Bool {
    notebook.objects.contains { object in
      guard selection.contains(object.id), case .ink = object.content else { return false }
      return true
    }
  }

  @objc func eraseSelectedStrokes(_ sender: Any?) {
    let remaining = notebook.objects.filter { object in
      if selection.contains(object.id), case .ink = object.content { return false }
      return true
    }
    didChange(from: notebook.objects, to: remaining, name: "Erase Selected Strokes")
    setSelection(selection.intersection(remaining.map(\.id)))
  }

  @objc func delete(_ sender: Any?) {
    guard hasSelection else { return }
    didChange(
      from: notebook.objects, to: notebook.objects.filter { !selection.contains($0.id) },
      name: "Delete Selection")
    setSelection([])
  }

  override func selectAll(_ sender: Any?) {
    chooseTool(.selector)
    setSelection(Set(notebook.objects.map(\.id)))
  }

  @objc func copy(_ sender: Any?) {
    let objects = notebook.objects.filter { selection.contains($0.id) }
    guard !objects.isEmpty, let data = try? PropertyListEncoder().encode(objects) else { return }
    clipboard.clearContents()
    clipboard.setData(data, forType: Self.objectsType)
    if objects.count == 1, let object = objects.first {
      switch object.content {
      case .text(let text, _, _): clipboard.setString(text, forType: .string)
      case .image(let image): clipboard.setData(image, forType: .png)
      case .ink: break
      }
    }
  }

  @objc func cut(_ sender: Any?) {
    copy(sender)
    delete(sender)
  }

  @objc func paste(_ sender: Any?) {
    guard active else { return }
    if let data = clipboard.data(forType: Self.objectsType),
      let objects = try? PropertyListDecoder().decode([NoteObject].self, from: data),
      !objects.isEmpty
    {
      insertCopies(objects)
      return
    }
    if let data = clipboard.data(forType: .png) ?? clipboard.data(forType: .tiff) {
      importImage(data)
      return
    }
    if let urls = clipboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty
    {
      for url in urls { importImage(from: url) }
      return
    }
    if let text = clipboard.string(forType: .string),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let (value, code) = CodeFormat.recognize(text)
      var object = textObject(at: insertionOrigin, text: value)
      if code || preferences.code {
        object.codeStyle = true
        sizeCode(&object)
      }
      insert([object], name: "Paste Text")
    }
  }

  func insertStudyResult(_ value: String) {
    insert([textObject(at: insertionOrigin, text: value)], name: "Insert Study Result")
  }
  private var insertionOrigin: CGPoint {
    let visible = visibleRect
    let x = max(paperGrid * 4.6, visible.minX + 18)
    return CGPoint(
      x: min(paperSize.width - 100, x), y: visible.minY + min(50, visible.height * 0.15))
  }

  private func insert(_ objects: [NoteObject], name: String) {
    finishText()
    finishGesture()
    didChange(from: notebook.objects, to: notebook.objects + objects, name: name)
    chooseTool(.selector)
    setSelection(Set(objects.map(\.id)))
  }

  var selectedImageIndex: Int? {
    guard selection.count == 1 else { return nil }
    return notebook.objects.firstIndex {
      if case .image = $0.content { return selection.contains($0.id) }; return false
    }
  }
  @objc func fitSelectedImage(_ sender: Any?) {
    guard let i = selectedImageIndex else { return }
    var next = notebook.objects
    let f = next[i].frame, inset = paperGrid * 2
    let scale = min(
      (paperSize.width - 2 * inset) / f.width, (paperSize.height - 2 * inset) / f.height)
    let w = f.width * scale, h = f.height * scale,
      top = floor(f.minY / paperSize.height) * paperSize.height
    next[i].frame = CGRect(
      x: (paperSize.width - w) / 2,
      y: max(top + inset, min(f.minY, top + paperSize.height - h - inset)), width: w, height: h)
    next[i].layoutFrame = nil
    didChange(from: notebook.objects, to: next, name: "Fit Image to Page")
  }

  private func insertCopies(_ objects: [NoteObject]) {
    let group = objects.reduce(CGRect.null) { $0.union($1.frame) }
    guard !group.isNull, group.width > 0, group.height > 0, group.minX.isFinite, group.minY.isFinite
    else { return }
    let isVisible = visibleRect.intersects(group.insetBy(dx: -12, dy: -12))
    let location = isVisible ? group.origin + CGPoint(x: 12, y: 12) : insertionOrigin
    let dx = max(0, min(paperSize.width - group.width, max(0, location.x))) - group.minX
    let dy = max(0, location.y) - group.minY
    let copies = objects.map { object -> NoteObject in
      var copy = object.transformed(
        from: group.origin, scale: 1, offset: CGPoint(x: dx, y: dy))
      copy.id = UUID()
      return copy
    }
    insert(copies, name: "Paste Selection")
  }

  func importImage(from url: URL, at location: CGPoint? = nil) {
    do { importImage(try Data(contentsOf: url), at: location) } catch {
      reportError?("Couldn’t import the image", error)
    }
  }

  private func importImage(_ data: Data, at location: CGPoint? = nil) {
    do {
      let image = try PaperRenderer.importImage(data)
      let size = image.size
      let origin = location ?? insertionOrigin
      let point = CGPoint(
        x: max(0, min(origin.x, paperSize.width - size.width)), y: max(0, origin.y))
      insert(
        [.init(frame: CGRect(origin: point, size: size), content: .image(image.data))],
        name: "Insert Image")
    } catch { reportError?("Couldn’t use that image", error) }
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    active && sender.draggingPasteboard.availableType(from: [.png, .tiff, .fileURL]) != nil
      ? .copy : []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pb = sender.draggingPasteboard
    let point = convert(sender.draggingLocation, from: nil)
    if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
      importImage(data, at: point)
      return true
    }
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL], !urls.isEmpty
    {
      for url in urls { importImage(from: url, at: point) }
      return true
    }
    return false
  }

  private func textObject(at point: CGPoint, text: String = "") -> NoteObject {
    let x = min(paperSize.width - 92, max(5, point.x))
    let width = min(290, paperSize.width - x - 4)
    let size = preferences.textSize
    let color = InkColor.colors[preferences.textColor].1
    let string = PaperRenderer.attributed(
      text, color: color, size: size, alignment: preferences.textAlignment)
    let height = string.boundingRect(
      with: CGSize(width: width, height: 100_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    let frame = CGRect(x: x, y: max(0, point.y), width: width, height: max(24, ceil(height) + 7))
    return NoteObject(
      frame: frame, content: .text(text, color, size), alignment: preferences.textAlignment)
  }

  private func startText(at point: CGPoint, existing: NoteObject? = nil) {
    var object = existing ?? textObject(at: point)
    if existing == nil && preferences.code { object.codeStyle = true }
    if object.table != nil {
      beginCell(at: point, object: object)
      return
    }
    guard case .text(let text, let color, let size) = object.content else { return }
    setSelection([])
    textHistory.removeAllActions()
    let textView = NSTextView(frame: object.frame)
    textView.appearance = NSAppearance(named: .aqua)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = CGSize(width: object.frame.width, height: 100_000)
    textView.font =
      object.codeStyle == nil
      ? .systemFont(ofSize: size) : .monospacedSystemFont(ofSize: size, weight: .regular)
    textView.textColor = color.ns
    textView.backgroundColor = NSColor(srgbRed: 0.994, green: 1, blue: 0.994, alpha: 1)
    textView.insertionPointColor = .black
    textView.drawsBackground = true
    textView.string = text
    let style = NSMutableParagraphStyle()
    style.alignment = (object.alignment ?? .natural).value
    textView.defaultParagraphStyle = style
    textView.alignment = style.alignment
    textView.typingAttributes = [
      .font: textView.font!, .foregroundColor: color.ns, .paragraphStyle: style,
    ]
    textView.delegate = self
    if let style = object.codeStyle { tintEditor(textView, size: size, enabled: style) }
    textView.setAccessibilityLabel("Notebook text")
    textView.wantsLayer = true
    textView.layer?.borderWidth = 0.65
    textView.layer?.borderColor = appAccent.cgColor
    editing = TextEdit(object: object, view: textView, existing: existing != nil)
    addSubview(textView)
    window?.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
    invalidate(object.frame)
    positionDidChange?()
  }

  func undoManager(for view: NSTextView) -> UndoManager? { textHistory }

  func rememberInteraction(in position: inout ViewPosition) {
    position.tool = tool.rawValue
    position.selection =
      selection.isEmpty ? nil : selection.sorted { $0.uuidString < $1.uuidString }
    if let editing {
      position.editing = cellEdit?.object.id ?? editing.object.id
      position.cell = cellEdit?.index
      let range = editing.view.selectedRange()
      position.caret = range.location
      position.selectionLength = range.length
    }
  }

  func restoreInteraction(_ position: ViewPosition) {
    tool = NoteTool(rawValue: position.tool ?? "") ?? .brush
    setSelection(Set(position.selection ?? []).intersection(notebook.objects.map(\.id)))
    if let id = position.editing, let object = notebook.objects.first(where: { $0.id == id }),
      case .text = object.content
    {
      if let cell = position.cell, object.table != nil {
        beginCell(at: object.frame.origin, object: object, index: cell)
      } else {
        startText(at: object.frame.origin, existing: object)
      }
      if let view = editing?.view {
        let length = view.string.utf16.count
        let start = max(0, min(length, position.caret ?? length))
        view.setSelectedRange(
          NSRange(
            location: start, length: min(max(0, position.selectionLength ?? 0), length - start)))
      }
    }
  }

  func textViewDidChangeSelection(_ notification: Notification) { positionDidChange?() }

  var saveSnapshot: Notebook {
    var copy = notebook
    if let cellEdit, let editing,
      let i = copy.objects.firstIndex(where: { $0.id == cellEdit.object.id })
    {
      copy.objects[i].table?.cells[cellEdit.index] = editing.view.string
    } else if let editing {
      let view = editing.view
      if case .text(_, let color, let size) = editing.object.content {
        var object = editing.object
        object.frame = view.frame
        object.content = .text(view.string, color, size)
        sizeCode(&object)
        let empty = view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let index = copy.objects.firstIndex(where: { $0.id == object.id }) {
          if empty { copy.objects.remove(at: index) } else { copy.objects[index] = object }
        } else if !empty {
          copy.objects.append(object)
        }
      }
    }
    if !copy.objects.contains(where: { $0.id == draftID }), let object = draftInk() {
      copy.objects.append(object)
    }
    return copy
  }

  private func tintEditor(_ view: NSTextView, size: CGFloat, enabled: Bool) {
    guard let manager = view.layoutManager else { return }
    let value = CodeFormat.attributed(view.string, size: size, highlighted: enabled)
    let range = NSRange(location: 0, length: value.length)
    manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
    value.enumerateAttribute(.foregroundColor, in: range) { color, r, _ in
      if let color {
        manager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: r)
      }
    }
  }

  func textDidChange(_ notification: Notification) {
    guard let editing else { return }
    let view = editing.view
    if let style = editing.object.codeStyle, case .text(_, _, let size) = editing.object.content {
      tintEditor(view, size: size, enabled: style)
    }
    if cellEdit == nil, let container = view.textContainer, let layout = view.layoutManager {
      layout.ensureLayout(for: container)
      let height = max(24, layout.usedRect(for: container).maxY + 6)
      if abs(height - view.frame.height) > 0.5 {
        view.setFrameSize(CGSize(width: view.frame.width, height: height))
      }
    }
    notebook.revision += 1
    didEdit?()
  }

  func finishText(cancel: Bool = false) {
    guard let editing else { return }
    self.editing = nil
    positionDidChange?()
    let view = editing.view
    if window?.firstResponder === view { window?.makeFirstResponder(self) }
    view.removeFromSuperview()
    invalidate(editing.object.frame.union(view.frame))
    if let cell = cellEdit {
      cellEdit = nil
      if !cancel, let i = notebook.objects.firstIndex(where: { $0.id == cell.object.id }) {
        var next = notebook.objects
        next[i].table?.cells[cell.index] = view.string
        didChange(from: notebook.objects, to: next, name: "Edit Table Cell")
      } else if cancel {
        notebook.revision += 1
        didEdit?()
      }
      setSelection([cell.object.id])
      return
    }
    if cancel {
      notebook.revision += 1
      didEdit?()
      return
    }
    guard case .text(let oldText, let color, let size) = editing.object.content else { return }
    let isEmpty = view.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if !editing.existing && isEmpty { return }
    if editing.existing && view.string == oldText { return }
    var object = editing.object
    object.content = .text(view.string, color, size)
    object.frame = view.frame
    sizeCode(&object)
    var next = notebook.objects
    if let index = next.firstIndex(where: { $0.id == object.id }) {
      if isEmpty { next.remove(at: index) } else { next[index] = object }
    } else {
      next.append(object)
    }
    didChange(from: notebook.objects, to: next, name: editing.existing ? "Edit Text" : "Add Text")
  }

  private func draftInk() -> NoteObject? {
    guard let color = inkColor else { return nil }
    var object = NoteObject.ink(
      smoothedInk(ink, amount: inkSmoothing, times: inkTimes), color: color, id: draftID)
    if tool == .marker {
      object?.instrument = "marker"
      object?.opacity = preferences.markerOpacity
    }
    return object
  }
  private func measure(_ frame: CGRect, at point: CGPoint, fixed: CGPoint) {
    guard preferences.guides else { return }
    let feedback = resizeFeedback(frame, targets: guideTargets, fixed: fixed, tolerance: 4 / scale)
    updateGuides(feedback.guides)
    var text = String(format: "%.1f × %.1f mm", frame.width * 25.4 / 72, frame.height * 25.4 / 72)
    if !feedback.matches.isEmpty { text += " · " + feedback.matches.joined(separator: "+") }
    let label = NSAttributedString(
      string: text,
      attributes: [.font: ChromeTheme.current.font(11 / scale), .foregroundColor: NSColor.white])
    let w = label.size().width + 12 / scale, h = label.size().height + 6 / scale
    let f = CGRect(
      x: max(visibleRect.minX, min(visibleRect.maxX - w, point.x + 10 / scale)),
      y: max(visibleRect.minY, min(visibleRect.maxY - h, point.y + 12 / scale)), width: w, height: h
    )
    if let old = measurement { invalidate(old.frame) }
    measurement = (label, f)
    invalidate(f)
  }
  private func updateGuides(_ next: [AlignGuide]) {
    guard activeGuides != next else { return }
    for g in activeGuides + next { invalidate(g.bounds, padding: 2 / scale) }
    activeGuides = next
  }
  private func updateBlock(to point: CGPoint, shift: Bool) {
    guard let start = gestureOrigin else { return }
    if let old = blockPreview { invalidate(old.frame) }
    if tool == .shapes {
      let p = CGPoint(x: min(paperSize.width - 3, max(3, point.x)), y: max(3, point.y))
      blockPreview =
        start.distance(to: p) > 1
        ? shapeInk(
          start, p, shape: preferences.shape, constrained: shift || preferences.constrain,
          width: preferences.shapeWidth, color: currentColor) : nil
    } else {
      var f = rectBetween(start, point)
      if start.distance(to: point) < 4 / scale {
        f = CGRect(origin: start, size: preferences.tableSize)
      }
      f.size.width = min(paperSize.width, max(36, f.width))
      f.size.height = min(paperSize.height, max(18, f.height))
      f.origin.x = max(0, min(paperSize.width - f.width, f.minX))
      blockPreview = NoteObject(
        frame: f, content: .text("", InkColor.colors[0].1, 11), table: preferences.grid)
    }
    if let next = blockPreview { invalidate(next.frame) }
  }
  func configureTable(rows: Int, columns: Int, header: Bool, size: CGSize) {
    preferences.grid = TableGrid(rows: rows, columns: columns, header: header)
    preferences.tableSize = CGSize(
      width: min(paperSize.width, max(36, size.width)),
      height: min(paperSize.height, max(18, size.height)))
    guard var o = selectedObject, let grid = o.table,
      let index = notebook.objects.firstIndex(where: { $0.id == o.id })
    else { return }
    o.table = grid.resized(rows: rows, columns: columns, header: header)
    o.frame.size = preferences.tableSize
    o.frame.origin.x = min(o.frame.minX, paperSize.width - o.frame.width)
    o.layoutFrame = nil
    var next = notebook.objects
    next[index] = o
    didChange(from: notebook.objects, to: next, name: "Change Table")
  }
  private func beginCell(at point: CGPoint, object: NoteObject, index: Int? = nil) {
    guard let grid = object.table, case .text(_, let color, let size) = object.content else {
      return
    }
    let layout = object.layoutFrame ?? object.frame
    guard
      let i = index
        ?? grid.cells.indices.first(where: { grid.cell($0, in: layout).contains(point) }),
      grid.cells.indices.contains(i)
    else { return }
    let f = grid.cell(i, in: layout).intersection(object.frame).insetBy(dx: 2, dy: 1)
    guard f.width > 0 && f.height > 0 else { return }
    let proxy = NoteObject(
      id: object.id, frame: f, content: .text(grid.cells[i], color, min(size, f.height * 0.64)))
    cellEdit = (object, i)
    startText(at: f.origin, existing: proxy)
  }
  private func sizeCode(_ o: inout NoteObject) {
    if o.codeStyle == nil, o.table == nil, case .text(let value, let color, let size) = o.content {
      let (source, recognized) = CodeFormat.recognize(value)
      if recognized {
        o.codeStyle = true
        o.content = .text(source, color, size)
      }
    }
    guard let style = o.codeStyle, case .text(let value, _, let size) = o.content else { return }
    let h = CodeFormat.attributed(value, size: size, highlighted: style).boundingRect(
      with: CGSize(width: max(1, o.frame.width - 10), height: 100000),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    o.frame.size.height = max(24, ceil(h) + 8)
  }
  private func updateCodeButton() {
    codeButton?.removeFromSuperview()
    codeButton = nil
    guard [.selector, .text].contains(effectiveTool), let o = selectedObject,
      let style = o.codeStyle
    else { return }
    let b = NSButton(title: "</>", target: self, action: #selector(toggleCodeStyle(_:)))
    b.toolTip = style ? "Turn syntax colors off" : "Turn syntax colors on"
    b.setAccessibilityLabel(b.toolTip!)
    b.bezelStyle = .accessoryBarAction
    let u = 1 / max(0.1, scale)
    b.frame = CGRect(
      x: o.frame.maxX - 33 * u, y: max(0, o.frame.minY - 18 * u), width: 33 * u, height: 18 * u)
    addSubview(b)
    codeButton = b
  }
  @objc private func toggleCodeStyle(_ sender: Any?) {
    guard let o = selectedObject, let style = o.codeStyle,
      let i = notebook.objects.firstIndex(where: { $0.id == o.id })
    else { return }
    var next = notebook.objects
    next[i].codeStyle = !style
    didChange(from: notebook.objects, to: next, name: "Toggle Syntax Colors")
    updateCodeButton()
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 51, 117: delete(nil)
    case 53: setSelection([])
    default: super.keyDown(with: event)
    }
  }
}
