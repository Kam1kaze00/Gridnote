import AppKit

enum EraseMode: String, CaseIterable {
  case regular = "Regular"
  case stroke = "Stroke"
  case box = "Rectangle"
  case lasso = "Lasso"
}
enum TypeAlignment: String, Codable, CaseIterable {
  case natural = "Auto"
  case center = "Center"
  case right = "Right"
  case left = "Left"
  var value: NSTextAlignment {
    switch self {
    case .natural: return .natural
    case .center: return .center
    case .right: return .right
    case .left: return .left
    }
  }
}

final class ToolOptionsController: NSViewController {
  private let tool: NoteTool
  private let canvas: NoteCanvas
  private var preferences: PenPreferences { canvas.preferences }
  private let column = chromeStack([], spacing: 11, horizontal: false)
  private let settings:
    [(String, ClosedRange<Double>, ReferenceWritableKeyPath<PenPreferences, Double>, String)]
  private var readouts: [NSTextField] = []
  private var colors: [ChromeButton] = []
  var didInsert: (() -> Void)?
  var didRestore: (() -> Void)?
  private var diameterSlider: NSSlider?
  private var widthSlider: NSSlider?
  private var responseSlider: NSSlider?
  private var pressureSwitch: NSButton?
  private var preview: BrushSample?
  private var tableFields: [NSTextField] = []
  private var headerCheck: NSButton?

  init(tool: NoteTool, canvas: NoteCanvas) {
    self.tool = tool
    self.canvas = canvas
    switch tool {
    case .brush:
      settings = [
        ("Width", 0.7...6, \.width, "%.1f pt"), ("Smoothing", 0...1, \.smoothing, "%.0f%%"),
        ("Pressure response", 0.5...2, \.pressure, "%.2f×"),
      ]
    case .eraser: settings = [("Contact diameter", 6...36, \.eraserDiameter, "%.0f pt")]
    case .text: settings = [("Type size", 8...36, \.textSize, "%.0f pt")]
    case .selector, .table: settings = []
    case .marker:
      settings = [
        ("Width", 3...24, \.markerWidth, "%.1f pt"),
        ("Opacity", 0.12...0.75, \.markerOpacity, "%.0f%%"),
      ]
    case .shapes: settings = [("Line width", 0.7...6, \.shapeWidth, "%.1f pt")]
    }
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = Surface(chromeToolbar)
    view.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      column.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
    ])
    column.addArrangedSubview(
      chromeLabel(
        tool.title, size: 15, weight: .semibold))
    switch tool {
    case .brush:
      let sample = BrushSample(preferences: preferences)
      sample.heightAnchor.constraint(equalToConstant: 31).isActive = true
      sample.widthAnchor.constraint(equalToConstant: 248).isActive = true
      column.addArrangedSubview(sample)
      preview = sample
      let nibs = WritingTip.allCases
      segment(
        "Writing tip", labels: nibs.map(\.rawValue),
        selected: nibs.firstIndex(of: preferences.nib) ?? 1,
        action: #selector(nibChanged(_:)))
      let toggle = NSButton(
        checkboxWithTitle: "Use pen pressure", target: self, action: #selector(pressureChanged(_:)))
      pressureSwitch = toggle
      column.addArrangedSubview(toggle)
      syncPressure()
    case .marker: break
    case .shapes:
      segment(
        "Shape", labels: ShapeKind.allCases.map(\.rawValue),
        selected: ShapeKind.allCases.firstIndex(of: preferences.shape)!,
        action: #selector(shapeChanged(_:)))
      check(
        "Constrain angles and proportions", preferences.constrain, #selector(constrainChanged(_:)))
    case .table:
      tableOptions()
    case .selector:
      check("Alignment guides", preferences.guides, #selector(guidesChanged(_:)))
      if canvas.selectedObject?.table != nil { tableOptions() }
      segment(
        "Selection shape", labels: SelectMode.allCases.map(\.rawValue),
        selected: SelectMode.allCases.firstIndex(of: canvas.selectMode)!,
        action: #selector(selectShape(_:)))
      column.addArrangedSubview(
        chromeLabel("Include in selection", size: 11, weight: .medium, color: chromeMuted))
      let checks = ["Ink", "Text", "Images"].enumerated().map { index, label in
        let check = NSButton(
          checkboxWithTitle: label, target: self, action: #selector(filterChanged(_:)))
        check.tag = 1 << index
        check.state = preferences.selectionMask & check.tag != 0 ? .on : .off
        return check
      }
      column.addArrangedSubview(chromeStack(checks, spacing: 14))
    case .eraser:
      segment(
        "Eraser mode", labels: EraseMode.allCases.map(\.rawValue),
        selected: EraseMode.allCases.firstIndex(of: preferences.eraseMode)!,
        action: #selector(eraseShape(_:)))
    case .text:
      check("Insert code block", preferences.code, #selector(codeChanged(_:)))
      formatOptions(table: false)
    }
    for (i, item) in settings.enumerated() {
      let label = chromeLabel(item.0, size: 12, weight: .medium)
      let value = chromeLabel("", size: 11, color: chromeMuted)
      readouts.append(value)
      let row = chromeStack([label, NSView(), value])
      row.widthAnchor.constraint(equalToConstant: 248).isActive = true
      let slider = NSSlider(
        value: item.2 == \PenPreferences.textSize
          ? canvas.currentFormat(table: false).size : preferences[keyPath: item.2],
        minValue: item.1.lowerBound,
        maxValue: item.1.upperBound,
        target: self, action: #selector(slid(_:)))
      if item.2 == \PenPreferences.eraserDiameter {
        diameterSlider = slider
        updateDiameter()
      }
      if item.2 == \PenPreferences.width { widthSlider = slider }
      if item.2 == \PenPreferences.pressure {
        responseSlider = slider
        syncPressure()
      }
      slider.tag = i
      slider.controlSize = .small
      slider.isContinuous = true
      slider.setAccessibilityLabel(item.0)
      slider.widthAnchor.constraint(equalToConstant: 248).isActive = true
      column.addArrangedSubview(chromeStack([row, slider], spacing: 3, horizontal: false))
      display(i)
    }
    if [.brush, .shapes, .marker].contains(tool) && !preferences.paletteVisible {
      colors = (tool == .marker ? markerColors : InkColor.colors).enumerated().map { index, color in
        let button = ChromeButton(target: self, action: #selector(chooseInk(_:)))
        button.controlWidth = 29
        button.controlHeight = 26
        button.swatch = color.1.ns
        button.tag = index
        button.toolTip = color.0
        button.setAccessibilityLabel(color.0)
        button.selected =
          index
          == (tool == .marker
            ? preferences.markerIndex
            : tool == .text ? preferences.textColor : preferences.colorIndex)
        return button
      }
      column.addArrangedSubview(
        chromeStack([chromeLabel("Color", size: 12), NSView()] + colors, spacing: 4))
    }
    let reset = NSButton(
      title: "Restore tool defaults", target: self, action: #selector(restoreTool))
    reset.controlSize = .small
    column.addArrangedSubview(reset)
    view.layoutSubtreeIfNeeded()
    preferredContentSize = CGSize(
      width: max(280, ceil(column.fittingSize.width) + 32),
      height: ceil(column.fittingSize.height) + 30)
  }

  @objc private func restoreTool() {
    preferences.restore(tool)
    canvas.applySelectionFilters()
    canvas.refreshTool()
    didRestore?()
  }
  @objc private func nibChanged(_ sender: NSSegmentedControl) {
    preferences.nib = WritingTip.allCases[sender.selectedSegment]
    if let widthSlider { widthSlider.doubleValue = preferences.width; display(widthSlider.tag) }
    syncPressure()
    canvas.refreshTool()
  }
  @objc private func pressureChanged(_ sender: NSButton) {
    preferences.usePressure = sender.state == .on
    syncPressure()
  }
  private func syncPressure() {
    let supported = preferences.device.pressure && preferences.nib != .fineliner
    pressureSwitch?.state = supported && preferences.usePressure ? .on : .off
    pressureSwitch?.isEnabled = supported
    responseSlider?.isEnabled = supported && preferences.usePressure
    preview?.needsDisplay = true
  }
  private func check(_ label: String, _ on: Bool, _ action: Selector) {
    let b = NSButton(checkboxWithTitle: label, target: self, action: action)
    b.state = on ? .on : .off
    column.addArrangedSubview(b)
  }
  @objc private func shapeChanged(_ s: NSSegmentedControl) {
    preferences.shape = ShapeKind.allCases[s.selectedSegment]
    canvas.refreshTool()
  }
  @objc private func constrainChanged(_ s: NSButton) { preferences.constrain = s.state == .on }
  @objc private func codeChanged(_ s: NSButton) {
    preferences.code = s.state == .on
    canvas.refreshTool()
  }
  @objc private func guidesChanged(_ s: NSButton) { preferences.guides = s.state == .on }
  private func tableOptions() {
    let selected = canvas.selectedObject
    if tool == .table {
      let hint = chromeLabel("Insert by grid", size: 11, color: chromeMuted)
      let picker = TablePicker()
      picker.preview = { [weak hint] cols, rows in hint?.stringValue = "\(cols) × \(rows)" }
      picker.insert = { [weak self] cols, rows in
        self?.canvas.insertGrid(rows: rows, columns: cols)
        self?.didInsert?()
      }
      column.addArrangedSubview(chromeStack([picker, hint], spacing: 8))
    }
    let grid = selected?.table ?? preferences.grid
    let size = selected?.table != nil ? selected!.frame.size : preferences.tableSize
    let values = [grid.rows, grid.columns, Int(size.width.rounded()), Int(size.height.rounded())]
    let labels = ["Rows", "Columns", "Width (pt)", "Height (pt)"]
    for row in [0, 2] {
      var controls: [NSView] = []
      for i in row...row + 1 {
        let f = NSTextField(string: String(values[i]))
        f.widthAnchor.constraint(equalToConstant: 49).isActive = true
        f.target = self
        f.action = #selector(changeTable(_:))
        f.setAccessibilityLabel(labels[i])
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = [40, 16, 595, 842][i] as NSNumber
        f.formatter = formatter
        f.cell?.sendsActionOnEndEditing = true
        tableFields.append(f)
        controls += [chromeLabel(labels[i], size: 11), f]
      }
      column.addArrangedSubview(chromeStack(controls, spacing: 7))
    }
    let b = NSButton(
      checkboxWithTitle: "Header row", target: self, action: #selector(changeTable(_:)))
    b.state = grid.header ? .on : .off
    headerCheck = b
    column.addArrangedSubview(b)
    formatOptions(table: true)
  }

  private var tableFormatting: Bool { tool == .table || tool == .selector }
  private func formatOptions(table: Bool) {
    let f = canvas.currentFormat(table: table)
    let title = table ? "Table text" : canvas.formatCell != nil ? "Cell text" : "Text style"
    let color = NSPopUpButton()
    color.controlSize = .small
    for ink in InkColor.colors { color.addItem(withTitle: ink.0) }
    color.selectItem(at: InkColor.colors.firstIndex(where: { $0.1 == f.color }) ?? 0)
    color.target = self
    color.action = #selector(formatColor(_:))
    color.setAccessibilityLabel("Text color")
    var row: [NSView] = [chromeLabel(title, size: 12, weight: .medium), NSView(), color]
    if table {
      let size = NSPopUpButton()
      size.controlSize = .small
      let sizes = Set([8, 10, 11, 12, 14, 16, 18, 24, 30, 36, Int(f.size.rounded())]).sorted()
      for pt in sizes { size.addItem(withTitle: "\(pt) pt"); size.lastItem?.tag = pt }
      size.selectItem(withTag: Int(f.size.rounded()))
      size.target = self
      size.action = #selector(formatSize(_:))
      size.setAccessibilityLabel("Table type size")
      row.append(size)
    }
    let header = chromeStack(row, spacing: 5)
    header.widthAnchor.constraint(equalToConstant: 248).isActive = true
    column.addArrangedSubview(header)
    let traits = NSSegmentedControl(
      labels: ["B", "I", "U"], trackingMode: .selectAny,
      target: self, action: #selector(formatTraits(_:)))
    traits.setAccessibilityLabel("Text emphasis")
    for (i, label) in ["Bold", "Italic", "Underline"].enumerated() {
      traits.setToolTip(label, forSegment: i)
      traits.setSelected(f.traits & (1 << i) != 0, forSegment: i)
    }
    let align = NSSegmentedControl(
      labels: TypeAlignment.allCases.map(\.rawValue),
      trackingMode: .selectOne, target: self, action: #selector(alignment(_:)))
    align.selectedSegment = TypeAlignment.allCases.firstIndex(of: f.alignment) ?? 0
    align.setAccessibilityLabel("Alignment")
    align.controlSize = .small
    traits.controlSize = .small
    column.addArrangedSubview(chromeStack([traits, align], spacing: 5))
  }
  @objc private func formatColor(_ sender: NSPopUpButton) {
    canvas.changeFormat(table: tableFormatting) {
      $0.color = InkColor.colors[sender.indexOfSelectedItem].1
    }
    canvas.refreshTool()
  }
  @objc private func formatSize(_ sender: NSPopUpButton) {
    canvas.changeFormat(table: true) { $0.size = CGFloat(sender.selectedTag()) }
  }
  @objc private func formatTraits(_ sender: NSSegmentedControl) {
    let mask = (0..<3).reduce(0) { $0 | (sender.isSelected(forSegment: $1) ? 1 << $1 : 0) }
    canvas.changeFormat(table: tableFormatting) { $0.traits = mask }
  }
  @objc private func changeTable(_ sender: Any?) {
    guard tableFields.count == 4 else { return }
    canvas.configureTable(
      rows: tableFields[0].integerValue, columns: tableFields[1].integerValue,
      header: headerCheck?.state == .on,
      size: CGSize(width: tableFields[2].doubleValue, height: tableFields[3].doubleValue))
    let grid = preferences.grid, size = preferences.tableSize
    for (field, value) in zip(
      tableFields, [grid.rows, grid.columns, Int(size.width.rounded()), Int(size.height.rounded())])
    {
      field.integerValue = value
    }
    canvas.refreshTool()
  }

  private func segment(_ title: String, labels: [String], selected: Int, action: Selector) {
    let control = NSSegmentedControl(
      labels: labels, trackingMode: .selectOne, target: self, action: action)
    control.selectedSegment = selected
    control.segmentDistribution = .fillEqually
    control.widthAnchor.constraint(equalToConstant: 248).isActive = true
    control.setAccessibilityLabel(title)
    column.addArrangedSubview(
      chromeStack(
        [chromeLabel(title, size: 12, weight: .medium), control], spacing: 5, horizontal: false))
  }
  private func display(_ i: Int) {
    let item = settings[i]
    let value =
      (item.2 == \PenPreferences.textSize
        ? canvas.currentFormat(table: false).size : preferences[keyPath: item.2])
      * ((item.2 == \PenPreferences.smoothing || item.2 == \PenPreferences.markerOpacity) ? 100 : 1)
    if item.2 == \PenPreferences.pressure {
      let feel = abs(value - 1) < 0.005 ? "Linear" : value < 1 ? "Soft" : "Firm"
      readouts[i].stringValue = String(format: "%@ · %.2f", feel, value)
    } else {
      readouts[i].stringValue = String(format: item.3, value)
    }
  }
  @objc private func slid(_ slider: NSSlider) {
    let item = settings[slider.tag]
    let value = (slider.doubleValue * 100).rounded() / 100
    if item.2 == \PenPreferences.textSize {
      canvas.changeFormat(table: false) { $0.size = value }
    } else {
      preferences[keyPath: item.2] = value
    }
    display(slider.tag)
    preview?.needsDisplay = true
    canvas.refreshTool()
  }
  @objc private func selectShape(_ sender: NSSegmentedControl) {
    canvas.selectMode = SelectMode.allCases[sender.selectedSegment]
    canvas.refreshTool()
  }
  private func updateDiameter() {
    diameterSlider?.isEnabled = [.regular, .stroke].contains(preferences.eraseMode)
  }
  @objc private func eraseShape(_ sender: NSSegmentedControl) {
    preferences.eraseMode = EraseMode.allCases[sender.selectedSegment]
    updateDiameter()
    canvas.refreshTool()
  }
  @objc private func alignment(_ sender: NSSegmentedControl) {
    canvas.changeFormat(table: tableFormatting) {
      $0.alignment = TypeAlignment.allCases[sender.selectedSegment]
    }
    canvas.refreshTool()
  }
  @objc private func filterChanged(_ sender: NSButton) {
    if sender.state == .on {
      preferences.selectionMask |= sender.tag
    } else {
      preferences.selectionMask &= ~sender.tag
    }
    canvas.applySelectionFilters()
  }
  @objc private func chooseInk(_ sender: NSButton) {
    if tool == .text {
      preferences.textColor = sender.tag
    } else if tool == .marker {
      preferences.markerIndex = sender.tag
    } else {
      preferences.colorIndex = sender.tag
    }
    for color in colors { color.selected = color.tag == sender.tag }
    preview?.needsDisplay = true
    canvas.refreshTool()
  }
}

private final class BrushSample: NSView {
  let preferences: PenPreferences
  init(preferences: PenPreferences) {
    self.preferences = preferences
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: CGRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
    NSColor(white: 0.97, alpha: 1).setFill()
    path.fill()
    var points: [InkPoint] = []
    let style = preferences.writingStyle
    for i in 0...70 {
      let t = CGFloat(i) / 70
      let y = 15 + sin(t * 3 * .pi) * 6 + sin(t * 41) * 0.5
      let force = 0.1 + sin(.pi * t) * 0.9
      let radius = style.radius(at: preferences.device.pressure ? force : nil)
      points.append(
        InkPoint(position: CGPoint(x: 12 + t * (bounds.width - 24), y: y), radius: radius))
    }
    PaperRenderer().drawInk(
      smoothedInk(points, amount: preferences.smoothing),
      color: InkColor.colors[preferences.colorIndex].1, context: context)
  }
}
