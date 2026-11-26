import AppKit

enum WritingTip: String, CaseIterable {
  case pen = "Pen", brush = "Brush", fineliner = "Fineliner", gel = "Gel", fountain = "Fountain", pencil = "Pencil"

  var defaultWidth: Double {
    switch self {
    case .gel: return 2.5
    case .fountain: return 4.2
    case .pencil: return 2.1
    case .pen: return 1.5
    case .brush: return 2
    case .fineliner: return 0.9
    }
  }
}

struct WritingStyle {
  let tip: WritingTip
  let width: Double
  let usesPressure: Bool
  let exponent: Double
  var finish: BrushFinish = .inked
  var seed: Int? = nil

  var inkNib: InkNib? {
    [.brush, .gel, .fountain, .pencil].contains(tip) ? InkNib(tip: tip.rawValue, width: width, finish: tip == .brush ? finish : nil, seed: tip == .brush ? seed : nil) : nil
  }
  func radius(at force: Double?) -> CGFloat {
    guard usesPressure, tip != .fineliner, let force, force.isFinite else { return width / 2 }
    let level = pow(min(1, max(0, force)), exponent)
    let weight: Double
    switch tip {
    case .pen: weight = 0.74 + 0.36 * level * (0.72 + 0.28 * level)
    case .gel: weight = 0.94 + 0.12 * level
    case .fountain: weight = 0.75 + 0.48 * level
    case .pencil: weight = 0.32 + 1.35 * level
    case .brush: weight = 0.085 + (finish == .dry ? 3.04 * pow(level, 1.06) : 2.88 * pow(level, 1.16))
    case .fineliner: weight = 1
    }
    return width * weight / 2
  }

  func sampledRadius(force: Double?, previous: CGFloat?, distance: CGFloat, elapsed: Double,
                     lift: Bool, stylus: Bool, crossTilt: CGFloat = 0) -> CGFloat {
    guard usesPressure, tip != .fineliner else { return width / 2 }
    if lift, let previous {
      guard tip == .brush, distance >= 0.12 else { return previous }
      return max(radius(at: 0), previous * exp(-distance / max(1, CGFloat(width))))
    }
    let dt = max(0.001, elapsed)
    var contact = force
    if contact == nil && tip != .pen && !stylus {
      // A mouse has no load sensor. A slow pull spreads the brush, a flick narrows it.
      let speed = Double(distance) / dt
      contact = previous == nil ? 0.42 : 0.22 + 0.54 / (1 + speed / 230)
    }
    // A rolling ball deposits a little more ink on a slow line. Without a load
    // sensor, use a normal writing load rather than switching to solid felt ink.
    if tip == .pen {
      let speed = Double(distance) / dt
      let load = contact ?? (stylus ? nil : 0.62)
      if let load {
        let dwell = previous == nil ? 0 : 0.13 * (1 / (1 + speed / 180) - 0.40)
        contact = min(1, max(0, load + dwell))
      }
    }
    guard let contact else { return previous ?? width / 2 }
    let tiltGain: CGFloat = tip == .brush ? 0.65 : tip == .pencil ? 1.5 : 0
    let spread = 1 + tiltGain * min(1, abs(crossTilt)) * contact
    let target = radius(at: contact) * spread
    guard let previous else { return target }
    let response = tip == .brush ? (target > previous ? 0.014 : 0.007) : 0.0035
    return target + (previous - target) * CGFloat(exp(-dt / response))
  }
  func fittedInk(_ raw: [InkPoint], smoothing: CGFloat, times: [TimeInterval] = [],
                 starts: Bool = true, lifted: Bool = false, marker: Bool = false) -> [InkPoint] {
    var points = smoothedInk(raw, amount: smoothing, times: times, technical: tip == .fineliner && !marker)
    guard tip == .brush, usesPressure, points.count >= 2 else { return points }
    if starts { taper(&points, fromStart: true) }
    if lifted { taper(&points, fromStart: false) }
    return points
  }

  // Work in paper distance so a sparse pair of samples and a high-rate tablet
  // have the same pointed tip. A tap keeps its full contact patch.
  private func taper(_ points: inout [InkPoint], fromStart: Bool) {
    let step = fromStart ? 1 : -1
    let first = fromStart ? 0 : points.count - 1
    let limit = width * (fromStart ? 1.25 : 2.2)
    var index = first, run: CGFloat = 0
    while points.indices.contains(index + step), run < 3 * limit {
      run += points[index].position.distance(to: points[index + step].position)
      index += step
    }
    guard run > 0.6 * width else { return }
    let span = min(limit, run / 3)
    let strength = min(1, (run / width - 0.6) / 1.5)
    var distance: CGFloat = 0
    index = first
    var traveled: [CGFloat] = [0]
    while points.indices.contains(index + step) {
      let next = index + step, a = points[index], b = points[next]
      let segment = a.position.distance(to: b.position)
      if distance + segment >= span {
        let t = (span - distance) / max(0.000001, segment)
        let shoulder = a.interpolated(to: b, by: t)
        let endRadius = shoulder.radius * (1 - strength * (fromStart ? 0.72 : 0.92))
        for (offset, d) in traveled.enumerated() {
          let n = first + step * offset
          let cap = endRadius + (shoulder.radius - endRadius) * d / span
          points[n].radius = min(points[n].radius, max(0.035 * width, cap))
        }
        if t > 0.001 && t < 0.999 { points.insert(shoulder, at: max(index, next)) }
        break
      }
      distance += segment
      traveled.append(distance)
      index = next
    }
  }

}

final class PenPreferences {
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Discard retired interface preferences without resetting pen or device tuning.
    for key in ["StudyMajor", "NotebookAppearance", "CartoonAppearance"]
    where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
    applyPendingTuning()
  }

  private var connection = InputDevice.connected()
  var device: InputDevice { connection.profile }
  var deviceDescription: String {
    connection.name.map { $0 + " · Detected" } ?? "Ready for pen or mouse"
  }
  func detectDevice(vendor: Int? = nil) {
    connection = InputDevice.connected(vendor: vendor)
    applyPendingTuning()
  }
  func recognizeTabletPoint() {
    if device == .mouse {
      connection = (.other, "Active pen")
      applyPendingTuning()
    }
  }
  private func setTuning(_ key: String, _ setting: Any) {
    defaults.set(setting, forKey: deviceKey(key))
    if device == .mouse {
      var pending = defaults.dictionary(forKey: "PendingWriterTuning") ?? [:]
      pending[key] = setting
      defaults.set(pending, forKey: "PendingWriterTuning")
    }
  }
  private func applyPendingTuning() {
    guard device.pressure, let pending = defaults.dictionary(forKey: "PendingWriterTuning") else { return }
    for (key, setting) in pending { defaults.set(setting, forKey: deviceKey(key)) }
    defaults.removeObject(forKey: "PendingWriterTuning")
  }
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
    set { setTuning("Smoothing", newValue) }
  }
  func toolAppearance(_ tool: NoteTool) -> (name: String, symbol: String) {
    switch tool {
    case .brush:
      let symbol: String
      switch nib {
      case .pen: symbol = "pencil.tip"
      case .brush: symbol = "paintbrush.pointed"
      case .fineliner: symbol = "pencil.line"
      case .gel: symbol = "highlighter"
      case .fountain: symbol = "fountainpen.tip"
      case .pencil: symbol = "pencil"
      }
      return (nib.rawValue, symbol)
    case .selector:
      return (selectionMode.rawValue, [.tap: "cursorarrow", .box: "rectangle.dashed", .lasso: "lasso"][selectionMode]!)
    case .eraser:
      return (eraseMode.rawValue, [.regular: "eraser", .stroke: "eraser.fill", .box: "square.dashed", .lasso: "lasso"][eraseMode]!)
    case .text:
      if code { return ("Code", "chevron.left.forwardslash.chevron.right") }
      return ("Text", [.natural: "textformat", .left: "text.alignleft", .center: "text.aligncenter", .right: "text.alignright"][textAlignment]!)
    case .marker: return ("Highlighter", "highlighter")
    case .shapes:
      return (shape.rawValue, [.line: "line.diagonal", .arrow: "arrow.up.right", .rectangle: "rectangle", .ellipse: "oval", .axes: "chart.xyaxis.line"][shape]!)
    case .table: return (tableHeader ? "Table with header" : "Table", tableHeader ? "rectangle.topthird.inset.filled" : "tablecells")
    }
  }

  private var legacyTip: WritingTip {
    WritingTip(rawValue: defaults.string(forKey: deviceKey("Nib")) ?? "") ?? .brush
  }
  var nib: WritingTip {
    get { WritingTip(rawValue: defaults.string(forKey: "WritingTip") ?? "") ?? legacyTip }
    set { defaults.set(newValue.rawValue, forKey: "WritingTip") }
  }
  var usePressure: Bool {
    get { defaults.object(forKey: deviceKey("UsePressure")) as? Bool ?? true }
    set { setTuning("UsePressure", newValue) }
  }
  var brushFinish: BrushFinish {
    get { BrushFinish(rawValue: defaults.string(forKey: "BrushFinish") ?? "") ?? .inked }
    set { defaults.set(newValue.rawValue, forKey: "BrushFinish") }
  }
  var penFlow: Double {
    get { value("PenFlow", fallback: 1, range: 0.25...1) }
    set { defaults.set(newValue, forKey: "PenFlow") }
  }
  var writingStyle: WritingStyle {
    WritingStyle(
      tip: nib, width: width, usesPressure: usePressure, exponent: pressure, finish: brushFinish)
  }
  func restore(_ tool: NoteTool? = nil) {
    let scoped: [NoteTool: [String]] = [
      .brush: ["Nib", "UsePressure", "BrushWidth", "Smoothing", "Pressure"],
      .eraser: ["EraserDiameter"],
    ]
    let common: [NoteTool: [String]] = [
      .brush: ["InkColor", "WritingTip", "BrushFinish", "PenFlow", "PendingWriterTuning"] + WritingTip.allCases.map { "Width." + $0.rawValue },
      .selector: ["SelectionMode", "SelectionMask", "AlignmentGuides"],
      .eraser: ["EraseMode"],
      .text: ["TextSize", "TextAlignment", "TextColor", "CodeBlocks", "TextTraits"],
      .marker: ["MarkerWidth", "MarkerOpacity", "MarkerColor"],
      .shapes: ["ShapeWidth", "Shape", "ConstrainShape"],
      .table: [
        "TableRows", "TableColumns", "TableHeader", "TableWidth", "TableHeight", "TableTextFormat",
      ]
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
    }
  }
  var pressure: Double {
    get { deviceValue("Pressure", fallback: 1, range: 0.50...2) }
    set { setTuning("Pressure", newValue) }
  }
  var width: Double {
    get {
      let tip = nib
      let fallback =
        tip == legacyTip
        ? deviceValue("BrushWidth", fallback: tip.defaultWidth, range: 0.7...6) : tip.defaultWidth
      return value("Width." + tip.rawValue, fallback: fallback, range: 0.7...6)
    }
    set { defaults.set(newValue, forKey: "Width." + nib.rawValue) }
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
  var labelFormat: NotebookTextFormat {
    get {
      .init(
        size: textSize, color: InkColor.colors[textColor].1, alignment: textAlignment,
        traits: defaults.integer(forKey: "TextTraits"))
    }
    set {
      textSize = newValue.size
      textAlignment = newValue.alignment
      if let i = InkColor.colors.firstIndex(where: { $0.1 == newValue.color }) { textColor = i }
      defaults.set(newValue.traits, forKey: "TextTraits")
    }
  }
  var tableFormat: NotebookTextFormat {
    get {
      if let data = defaults.data(forKey: "TableTextFormat"),
        let format = try? JSONDecoder().decode(NotebookTextFormat.self, from: data)
      {
        return format
      }
      return .init(size: 11)
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "TableTextFormat") }
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

enum NoteTool: String, CaseIterable {
  case brush, selector, eraser, text, marker, shapes, table
  var title: String {
    switch self {
    case .brush: return "Writer"
    case .marker: return "Highlighter"
    default: return rawValue.capitalized
    }
  }
}
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
  private var strokeStyle = WritingStyle(tip: .brush, width: 2, usesPressure: true, exponent: 1)
  private var brushLifted = false
  private var lastInkMotion: TimeInterval = 0
  private var inkSmoothing: CGFloat = 0
  private var inkTimes: [TimeInterval] = []
  private var draftID = UUID()
  private var lastCheckpoint: TimeInterval = 0
  private var liveSegments: [InkFootprint] = []
  private var ballpointWidth: CGFloat?
  private var inkFlow: CGFloat = 1
  private var hasStylusPressure = false
  private var previewStart = 0
  private var inkBounds = CGRect.null
  private var lastErase: CGPoint?
  private var gestureOrigin: CGPoint?
  private var tapText: NoteObject?
  private(set) var formatCell: Int?
  private var originalObjects: [NoteObject]?
  private var transformBounds: CGRect?
  private var transformMode: TransformMode?
  private var marquee: [CGPoint] = []
  private var originalSelection = Set<UUID>()
  private var additiveSelection = false
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
    let cell = cellEdit?.index
    let id = editing?.object.id
    finishText()
    if next == .text, let id, notebook.objects.contains(where: { $0.id == id }) {
      setSelection([id])
    }
    formatCell = next == .text ? cell : nil
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
      func section(_ start: Int, _ end: Int) -> InkFootprint {
        renderer.footprint(
          strokeStyle.fittedInk(
            Array(ink[start...end]), smoothing: inkSmoothing, times: Array(inkTimes[start...end]),
            starts: start == 0, marker: tool == .marker),
          ballpointWidth: ballpointWidth, nib: strokeStyle.inkNib)
      }
      while ink.count - previewStart > 100 {
        let end = previewStart + 96
        liveSegments.append(section(previewStart, end))
        previewStart = end
      }
      let tail = ink.count > previewStart ? section(previewStart, ink.count - 1) : nil
      let visible = liveSegments.filter { $0.body.boundingBoxOfPath.intersects(dirtyRect) }
      InkFootprint.paint(color: inkColor, hasCore: tail?.core != nil || visible.first?.core != nil, nib: strokeStyle.inkNib, flow: inkFlow, context: context) { core in
        for path in visible { path.add(to: context, core: core) }
        tail?.add(to: context, core: core)
      }
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
    var force: Double?
    if !usingLastPressure && preferences.device != .sidecarUSB {
      if event.isTabletSample {
        force = Double(event.tipPressure)
      } else if let last = lastTabletInput, last.tip,
        (0...0.15).contains(event.timestamp - last.timestamp),
        event.locationInWindow.distance(to: last.location) < 20
      {
        force = Double(last.pressure)
      } else if penInProximity && event.pressure > 0 && event.pressure < 1 {
        force = Double(event.pressure)
      }
    }
    if force != nil { hasStylusPressure = true }
    let delta = point - (ink.last?.position ?? point)
    let distance = delta.length
    var crossTilt: CGFloat = 0
    if (strokeStyle.tip == .brush || strokeStyle.tip == .pencil), event.isTabletSample, distance > 0.01 {
      let tilt = event.tilt
      crossTilt = (tilt.x * delta.y - tilt.y * delta.x) / distance
    }
    let radius = strokeStyle.sampledRadius(
      force: force, previous: ink.last?.radius, distance: distance,
      elapsed: event.timestamp - (inkTimes.last ?? event.timestamp),
      lift: usingLastPressure, stylus: hasStylusPressure, crossTilt: crossTilt)
    let clamped = CGPoint(
      x: min(paperSize.width - radius, max(radius, point.x)),
      y: min(bounds.height - radius, max(radius, point.y)))
    return InkPoint(position: clamped, radius: radius)
  }

  func appendInk(_ event: NSEvent, location: CGPoint, isLift: Bool = false) {
    guard inkColor != nil else { return }
    var point = sample(event, point: location, usingLastPressure: isLift)
    let moved = ink.last.map { point.position.distance(to: $0.position) >= 0.12 } ?? true
    if moved { lastInkMotion = event.timestamp }
    if isLift { brushLifted = event.timestamp - lastInkMotion <= 0.09 }
    if let previous = ink.last, !moved {
      if !isLift && abs(point.radius - previous.radius) > 0.005 {
        let index = ink.count - 1
        ink[index].radius = index == 0 ? max(previous.radius, point.radius) : point.radius
        inkTimes[index] = event.timestamp
        inkBounds = inkBounds.union(ink[index].bounds)
        invalidate(previous.bounds.union(ink[index].bounds).union(ink[max(0, index - 1)].bounds))
      }
      return
    }
    if strokeStyle.tip == .brush {
      point.recordBrushMotion(after: ink.last, width: strokeStyle.width,
        elapsed: event.timestamp - (inkTimes.last ?? event.timestamp))
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
      hasStylusPressure = false
      brushLifted = false
      draftID = UUID()
      lastCheckpoint = event.timestamp
      inkColor = tool == .marker ? markerColors[preferences.markerIndex].1 : currentColor
      strokeStyle =
        tool == .marker
        ? WritingStyle(
          tip: .fineliner, width: preferences.markerWidth, usesPressure: false, exponent: 1)
        : preferences.writingStyle
      if strokeStyle.tip == .brush { strokeStyle.seed = Int(draftID.uuid.0) }
      ballpointWidth = strokeStyle.tip == .pen ? strokeStyle.width : nil
      inkFlow = ballpointWidth == nil ? 1 : preferences.penFlow
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
        if case .text = o.content { return o }
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
      finishContact(at: point, event: event)
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

  func finishContact(at point: CGPoint, event: NSEvent) {
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
    let target = tapText
    finishGesture()
    if let target {
      startText(at: point, existing: target)
      if let view = editor {
        let caret = view.characterIndexForInsertion(at: view.convert(point, from: self))
        view.setSelectedRange(NSRange(location: min(view.string.utf16.count, caret), length: 0))
      }
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
        from: notebook.objects, to: notebook.objects + [object],
        name: tool == .marker ? "Highlight" : "Handwriting",
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
    tapText = nil
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
    additiveSelection = shift
    if !shift, let bounds = selectedBounds {
      let handles = corners(of: bounds.insetBy(dx: -selectionPadding, dy: -selectionPadding))
      if let index = handles.firstIndex(where: { $0.distance(to: point) <= 8 / max(0.1, scale) }) {
        startTransform(bounds: bounds, mode: .resize(anchor: corners(of: bounds)[(index + 2) % 4]))
        return
      }
      if bounds.insetBy(dx: -selectionPadding, dy: -selectionPadding).contains(point) {
        if selection.count == 1, let hit = object(at: point), selection.contains(hit.id),
          case .text = hit.content
        {
          tapText = hit
        }
        startTransform(bounds: bounds, mode: .move)
        return
      }
    }
    if !shift, selectMode == .tap, let hit = object(at: point) {
      setSelection([hit.id])
      if case .text = hit.content { tapText = hit }
      startTransform(bounds: hit.frame, mode: .move)
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
    if tapText != nil {
      guard start.distance(to: point) * scale > 4 else { return }
      tapText = nil
    }
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
        if !additiveSelection, case .text = hit.content { tapText = hit }
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
    formatCell = nil
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

  enum WritingKind { case handwriting, typedText }

  func clearWriting(_ kind: WritingKind, on page: Int? = nil) {
    finishText()
    finishGesture()
    let remaining = notebook.objects.flatMap { object -> [NoteObject] in
      switch (kind, object.content) {
      case (.handwriting, .ink) where object.instrument == nil,
           (.typedText, .text) where object.table == nil && object.codeStyle == nil:
        return page.map { removePageWriting(from: [object], page: $0) } ?? []
      default: return [object]
      }
    }
    guard remaining != notebook.objects else { return }
    didChange(from: notebook.objects, to: remaining,
      name: kind == .typedText ? "Remove Typed Text" : "Clear Writing")
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
    if objects.count == 1, case .image = objects[0].content {
      var copy = objects[0]
      copy.id = UUID()
      placeImage(copy, near: location)
      return
    }
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
      let object = NoteObject(frame: CGRect(origin: .zero, size: image.size), content: .image(image.data))
      placeImage(object, near: location ?? insertionOrigin, pageY: location?.y)
    } catch { reportError?("Couldn’t use that image", error) }
  }

  private func placeImage(_ object: NoteObject, near origin: CGPoint, pageY: CGFloat? = nil) {
    let visible = visibleRect
    let viewport = visible.isEmpty ? paperSize : visible.size
    let ptPerMM = 72.0 / 25.4
    let maxWidth = min(150 * ptPerMM, viewport.width * 0.85)
    let maxHeight = min(100 * ptPerMM, viewport.height * 0.6)
    let size = object.frame.size
    let factor = min(1, maxWidth / size.width, maxHeight / size.height)
    let focus = pageY ?? (visible.minY + min(visible.height * 0.24, 85))
    let top = max(0, floor(focus / paperSize.height)) * paperSize.height
    let point = CGPoint(
      x: max(paperGrid, min(origin.x, paperSize.width - paperGrid - size.width * factor)),
      y: max(top + paperGrid, min(origin.y, top + paperSize.height - paperGrid - size.height * factor)))
    let placed = object.transformed(from: object.frame.origin, scale: factor, offset: point - object.frame.origin)
    insert([placed], name: "Insert Image")
    scrollToVisible(placed.frame)
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
    let string = NSAttributedString(string: text, attributes: preferences.labelFormat.attributes())
    let height = string.boundingRect(
      with: CGSize(width: width, height: 100_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    let frame = CGRect(x: x, y: max(0, point.y), width: width, height: max(24, ceil(height) + 7))
    return NoteObject(
      frame: frame, content: .text(text, color, size), alignment: preferences.textAlignment,
      textTraits: preferences.labelFormat.traits)
  }

  private func startText(at point: CGPoint, existing: NoteObject? = nil) {
    var object = existing ?? textObject(at: point)
    if existing == nil && preferences.code { object.codeStyle = true }
    if object.table != nil {
      beginCell(at: point, object: object)
      return
    }
    guard case .text(let text, let color, _) = object.content else { return }
    setSelection(existing != nil && tool == .selector ? [object.id] : [])
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
    textView.font = object.textFormat.attributes(code: object.codeStyle != nil)[.font] as? NSFont
    textView.textColor = color.ns
    textView.backgroundColor = NSColor(srgbRed: 0.994, green: 1, blue: 0.994, alpha: 1)
    textView.insertionPointColor = .black
    textView.drawsBackground = true
    textView.string = text
    let style = NSMutableParagraphStyle()
    style.alignment = (object.alignment ?? .natural).value
    textView.defaultParagraphStyle = style
    textView.alignment = style.alignment
    var attributes = object.textFormat.attributes()
    attributes[.font] = textView.font!
    if textView.string.utf16.count > 0 {
      textView.textStorage?.setAttributes(
        attributes, range: NSRange(location: 0, length: textView.string.utf16.count))
    }
    textView.typingAttributes = attributes
    textView.delegate = self
    if let style = object.codeStyle {
      tintEditor(textView, format: object.textFormat, enabled: style)
    }
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

  private func tintEditor(_ view: NSTextView, format: NotebookTextFormat, enabled: Bool) {
    guard let manager = view.layoutManager else { return }
    let value = CodeFormat.attributed(view.string, format: format, highlighted: enabled)
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
    if let style = editing.object.codeStyle {
      tintEditor(view, format: editing.object.textFormat, enabled: style)
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
      strokeStyle.fittedInk(ink, smoothing: inkSmoothing, times: inkTimes, lifted: brushLifted,
                            marker: tool == .marker), color: color, id: draftID)
    object?.inkNib = strokeStyle.inkNib
    object?.ballpointWidth = ballpointWidth
    if ballpointWidth != nil && inkFlow < 1 { object?.opacity = inkFlow }
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
      attributes: [.font: NSFont.systemFont(ofSize: 11 / scale), .foregroundColor: NSColor.white])
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
      blockPreview = newTable(frame: f, grid: preferences.grid)
    }
    if let next = blockPreview { invalidate(next.frame) }
  }
  private func newTable(frame: CGRect, grid: TableGrid) -> NoteObject {
    let format = preferences.tableFormat
    return NoteObject(
      frame: frame, content: .text("", format.color, format.size),
      alignment: format.alignment, textTraits: format.traits, table: grid)
  }

  func insertGrid(rows: Int, columns: Int) {
    let grid = TableGrid(
      rows: rows, columns: columns, header: selectedObject?.table?.header ?? preferences.grid.header
    )
    preferences.grid = grid
    let size = CGSize(
      width: min(paperSize.width - 8, CGFloat(columns) * 72), height: CGFloat(rows) * 28)
    var origin = insertionOrigin
    origin.x = min(origin.x, paperSize.width - size.width)
    insert([newTable(frame: CGRect(origin: origin, size: size), grid: grid)], name: "Insert Table")
  }

  func formatTarget(table: Bool) -> NoteObject? {
    guard let object = selectedObject, case .text = object.content else { return nil }
    return table
      ? (object.table == nil ? nil : object)
      : (object.table == nil || formatCell != nil ? object : nil)
  }
  func currentFormat(table: Bool) -> NotebookTextFormat {
    if !table, let editing { return editing.object.textFormat }
    guard let object = formatTarget(table: table) else {
      return table ? preferences.tableFormat : preferences.labelFormat
    }
    if !table, let i = formatCell, let grid = object.table {
      return grid.formats?[grid.key(i)] ?? object.textFormat
    }
    return object.textFormat
  }
  func changeFormat(table: Bool, _ edit: (inout NotebookTextFormat) -> Void) {
    var style = currentFormat(table: table)
    edit(&style)
    guard var object = formatTarget(table: table),
      let i = notebook.objects.firstIndex(where: { $0.id == object.id })
    else {
      if table { preferences.tableFormat = style } else { preferences.labelFormat = style }
      return
    }
    if !table, let cell = formatCell, var grid = object.table {
      if grid.formats == nil { grid.formats = [:] }
      let key = grid.key(cell)
      grid.formats?[key] = style
      object.table = grid
    } else {
      object.textFormat = style
      if let overrides = object.table?.formats {
        object.table?.formats = overrides.mapValues {
          var f = $0; edit(&f); return f
        }
      }
      if object.table == nil, object.layoutFrame == nil,
        case .text(let value, _, _) = object.content
      {
        if object.codeStyle != nil {
          sizeCode(&object)
        } else {
          let string = NSAttributedString(string: value, attributes: style.attributes())
          object.frame.size.height = max(
            24,
            ceil(
              string.boundingRect(
                with: CGSize(width: object.frame.width, height: 100000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
              ).height) + 7)
        }
      }
    }
    var next = notebook.objects
    next[i] = object
    didChange(from: notebook.objects, to: next, name: "Format Text")
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
    guard let grid = object.table else {
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
    let style = grid.formats?[grid.key(i)] ?? object.textFormat
    let proxy = NoteObject(
      id: object.id, frame: f,
      content: .text(
        grid.cells[i], style.color, min(style.size, grid.cell(i, in: layout).height * 0.64)),
      alignment: style.alignment,
      textTraits: style.traits | (grid.header && i < grid.columns ? 1 : 0))
    cellEdit = (object, i)
    startText(at: f.origin, existing: proxy)
  }
  @discardableResult func advanceCell(backward: Bool) -> Bool {
    guard let cell = cellEdit else { return false }
    finishText()
    guard let object = selectedObject, let grid = object.table else { return true }
    let index = cell.index + (backward ? -1 : 1)
    if grid.cells.indices.contains(index) { beginCell(at: .zero, object: object, index: index) }
    return true
  }
  private func sizeCode(_ o: inout NoteObject) {
    if o.codeStyle == nil, o.table == nil, case .text(let value, let color, let size) = o.content {
      let (source, recognized) = CodeFormat.recognize(value)
      if recognized {
        o.codeStyle = true
        o.content = .text(source, color, size)
      }
    }
    guard let style = o.codeStyle, case .text(let value, _, _) = o.content else { return }
    let h = CodeFormat.attributed(value, format: o.textFormat, highlighted: style).boundingRect(
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
    finishText()
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
