import AppKit

enum PaperRuling: String, CaseIterable, Codable {
  case grid = "Grid"
  case ruled = "Ruled"
  case dotted = "Dotted"
  case plain = "Whiteboard"
}

enum PaperTint: String, CaseIterable, Codable {
  case white = "White"
  case ivory = "Ivory"
  case cream = "Cream"
  case blue = "Pale Blue"
  case sage = "Sage"
  case blush = "Blush"
  var color: NSColor {
    let rgb: (CGFloat, CGFloat, CGFloat)
    switch self {
    case .white: rgb = (1, 1, 1)
    case .ivory: rgb = (0.993, 0.979, 0.932)
    case .cream: rgb = (1, 0.958, 0.815)
    case .blue: rgb = (0.919, 0.959, 0.983)
    case .sage: rgb = (0.925, 0.957, 0.903)
    case .blush: rgb = (0.990, 0.932, 0.924)
    }
    return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
  }
}
struct PaperDesign: Codable, Equatable {
  var ruling: PaperRuling = .grid
  var tint: PaperTint = .white
  var cartoon: Bool?
  var stationery: String?
  var theme: NotebookTheme {
    stationery.flatMap(NotebookTheme.init(rawValue:)) ?? (cartoon == true ? .cartoon : .standard)
  }
  static func themed(_ theme: NotebookTheme) -> Self {
    let tint: PaperTint
    switch theme {
    case .tokyo: tint = .blue;
    case .pixel: tint = .sage;
    case .standard: tint = .white;
    default: tint = .ivory
    }
    return Self(
      ruling: .grid, tint: tint, cartoon: theme == .cartoon ? true : nil, stationery: theme.rawValue
    )
  }
  var paperInks: (base: Int, grid: Int, margin: Int, number: Int)? {
    switch theme {
    case .tokyo: return (0xf1f7f8, 0xb4c7d0, 0xe67169, 0x284b69)
    case .cyber: return (0xeff0e8, 0xb2bcae, 0xb2934e, 0x546052)
    case .pixel: return (0xf3f4df, 0xb5c19a, 0x849967, 0x506747)
    default: return nil
    }
  }
}

final class PaperPicker: NSViewController {
  private let canvas: NoteCanvas
  private let page: Int
  private var global: Bool
  private var ruling: NSSegmentedControl!
  private var colors: [ChromeButton] = []
  private let stationery = NSPopUpButton()
  private var colorLabel: NSTextField!
  init(canvas: NoteCanvas, page: Int) {
    self.canvas = canvas
    self.page = page
    global = canvas.notebook.sourceIndex(on: page) != nil
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = CGSize(width: 305, height: 214)
  }
  required init?(coder: NSCoder) { nil }
  override func loadView() {
    view = Surface(chromeToolbar)
    let scope = NSSegmentedControl(
      labels: ["This page", "Notebook default"], trackingMode: .selectOne, target: self,
      action: #selector(scopeChanged(_:)))
    scope.setEnabled(canvas.notebook.sourceIndex(on: page) == nil, forSegment: 0)
    scope.selectedSegment = global ? 1 : 0
    scope.setAccessibilityLabel("Apply paper to")
    scope.toolTip =
      "A page setting overrides the notebook default. Imported PDF pages keep their original paper."
    scope.widthAnchor.constraint(equalToConstant: 273).isActive = true
    ruling = NSSegmentedControl(
      labels: PaperRuling.allCases.map(\.rawValue), trackingMode: .selectOne, target: self,
      action: #selector(changeRuling(_:)))
    ruling.segmentDistribution = .fillEqually
    ruling.widthAnchor.constraint(equalToConstant: 273).isActive = true
    ruling.setAccessibilityLabel("Ruling")
    colorLabel = chromeLabel("", size: 11, weight: .medium, color: chromeMuted)
    colors = PaperTint.allCases.enumerated().map { index, tint in
      let button = ChromeButton(target: self, action: #selector(changeTint(_:)))
      button.swatch = tint.color
      button.controlWidth = 32
      button.controlHeight = 27
      button.tag = index
      button.toolTip = tint.rawValue
      button.setAccessibilityLabel(tint.rawValue)
      return button
    }
    stationery.addItems(withTitles: NotebookTheme.allCases.map(\.rawValue))
    stationery.target = self
    stationery.action = #selector(changeStationery(_:))
    stationery.setAccessibilityLabel("Stationery")
    let column = chromeStack(
      [
        chromeLabel("Paper", size: 15, weight: .semibold), scope,
        ruling, chromeStack([chromeLabel("Stationery"), stationery]), colorLabel,
        chromeStack(colors, spacing: 5),
      ], spacing: 9, horizontal: false)
    view.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      column.topAnchor.constraint(equalTo: view.topAnchor, constant: 13),
    ])
    refresh()
  }
  private var current: PaperDesign {
    global ? (canvas.notebook.defaultPaper ?? PaperDesign()) : canvas.notebook.paper(on: page)
  }
  private func refresh() {
    let design = current
    stationery.selectItem(withTitle: design.theme.rawValue)
    colorLabel.stringValue = "Paper color · " + design.tint.rawValue
    ruling.selectedSegment = PaperRuling.allCases.firstIndex(of: design.ruling)!
    for (index, button) in colors.enumerated() {
      button.selected = PaperTint.allCases[index] == design.tint
    }
  }
  @objc private func scopeChanged(_ sender: NSSegmentedControl) {
    global = sender.selectedSegment == 1
    refresh()
  }
  @objc private func changeRuling(_ sender: NSSegmentedControl) {
    var design = current
    design.ruling = PaperRuling.allCases[sender.selectedSegment]
    canvas.setPaper(design, on: global ? nil : page)
    refresh()
  }
  @objc private func changeStationery(_ sender: NSPopUpButton) {
    var design = current
    guard let title = sender.titleOfSelectedItem, let theme = NotebookTheme(rawValue: title) else {
      return
    }
    design.stationery = title
    design.cartoon = theme == .cartoon ? true : nil
    design.tint = PaperDesign.themed(theme).tint
    canvas.setPaper(design, on: global ? nil : page)
    refresh()
  }
  @objc private func changeTint(_ sender: NSButton) {
    var design = current
    design.tint = PaperTint.allCases[sender.tag]
    canvas.setPaper(design, on: global ? nil : page)
    refresh()
  }
}

final class PaperScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    if let canvas = documentView as? NoteCanvas, canvas.consumeDriverScroll(event) { return }
    let clip = contentView
    let units = event.hasPreciseScrollingDeltas ? 1 : max(1, verticalLineScroll)
    let delta = CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY) * units
    let rect = CGRect(origin: clip.bounds.origin - delta, size: clip.bounds.size)
    clip.scroll(to: clip.constrainBoundsRect(rect).origin)
    reflectScrolledClipView(clip)
  }
}
