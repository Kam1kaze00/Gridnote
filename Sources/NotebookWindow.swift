import AppKit
import PDFKit
import UniformTypeIdentifiers

extension UTType {
  static let gridnote = UTType(exportedAs: "app.gridnote.notebook", conformingTo: .data)
}

final class NotebookWindow: NSWindowController, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
  let canvas: NoteCanvas
  let scrollView = PaperScrollView()
  private let storage: NotebookStorage
  private let preferences: PenPreferences
  private var session: NotebookSession
  private(set) var notebookURL: URL?
  private var lastSavedRevision: UInt64?
  private var notebookSaveError: Error?
  private var sessionSaveError: Error?
  private var sessionTimer: Timer?
  private var hasSessionChanges = false
  private var framing = false
  private var zoom: CGFloat = 1
  private var lastLayoutWidth: CGFloat = 0
  private(set) var page = 0
  private var monitor: Any?
  private var preparingPDF = false
  private lazy var studySolver = StudySolver()
  private var scanID = UUID()
  private var lastScan: (id: UUID, revision: UInt64, page: Int, problems: [StudyProblem])?
  var requestLauncher: (() -> Void)?
  private var solveButton: ChromeButton!
  private var preview: PDFPreviewController?
  private(set) var settingsPopover: NSPopover?

  private let header = Surface(chromeBackground, movable: true)
  private let toolbar = Surface(chromeToolbar)
  private let footer = Surface(chromeBackground)
  private let workArea = NSView()
  private let pagesSidebar = PageSidebar()
  private var sidebarWidth: NSLayoutConstraint!
  private var pagesButton: ChromeButton!
  private let emptyArea = Surface(chromeBackground)
  private let documentName = chromeLabel("Gridnote", size: 15, weight: .semibold)
  private let pageLabel = chromeLabel("Page 1", weight: .semibold)
  private let zoomLabel = chromeLabel("100%", size: 11, weight: .medium, color: chromeMuted)
  private var toolbarHeight: NSLayoutConstraint!
  private var footerHeight: NSLayoutConstraint!
  private var toolButtons: [NoteTool: ChromeButton] = [:]
  private var colorButtons: [ChromeButton] = []
  private var palette: NSStackView!
  private var paletteButton: ChromeButton!
  private var optionsButton: ChromeButton!
  private var deviceLabel: NSTextField!
  private var selectionActions: ChromeButton!
  private var paperButton: ChromeButton!
  private var undoButton: ChromeButton!
  private var redoButton: ChromeButton!
  private var statusButton: ChromeButton!
  private var previewButton: ChromeButton!
  private var exportButton: ChromeButton!
  private var fitButton: ChromeButton!
  private var minZoomButton: ChromeButton!
  private var maxZoomButton: ChromeButton!

  init(
    storage: NotebookStorage = NotebookStorage(), preferences: PenPreferences = PenPreferences(),
    clipboard: NSPasteboard = .general
  ) {
    self.storage = storage
    session = (try? storage.loadSession()) ?? NotebookSession()
    self.preferences = preferences
    canvas = NoteCanvas(preferences: preferences, clipboard: clipboard)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1140, height: 770),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init(window: window)
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = chromeBackground
    window.title = "Gridnote"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.minSize = CGSize(width: 760, height: 470)
    window.isReleasedWhenClosed = false
    window.acceptsMouseMovedEvents = true
    window.setFrameAutosaveName("GridnoteWindow")
    if !window.setFrameUsingName("GridnoteWindow") { window.center() }
    window.delegate = self
    window.initialFirstResponder = canvas
    buildInterface()
    bindCanvas()
    showEmpty()
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
    NotificationCenter.default.removeObserver(self)
  }

  private func add(_ child: NSView, to parent: NSView) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
  }

  private func pin(_ child: NSView, to parent: NSView) {
    add(child, to: parent)
    NSLayoutConstraint.activate([
      child.topAnchor.constraint(equalTo: parent.topAnchor),
      child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
      child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
      child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
    ])
  }

  private func buildInterface() {
    let root = NSView()
    window?.contentView = root
    for view in [header, toolbar, workArea, footer] { add(view, to: root) }
    toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 47)
    footerHeight = footer.heightAnchor.constraint(equalToConstant: 34)
    for view in [header, toolbar, workArea, footer] {
      view.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
      view.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
    }
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.topAnchor),
      header.heightAnchor.constraint(equalToConstant: 51),
      toolbar.topAnchor.constraint(equalTo: header.bottomAnchor), toolbarHeight,
      workArea.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      workArea.bottomAnchor.constraint(equalTo: footer.topAnchor),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footerHeight,
    ])
    setupHeader()
    setupToolbar()
    setupFooter()
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.horizontalScrollElasticity = .none
    scrollView.verticalScrollElasticity = .none
    scrollView.drawsBackground = true
    scrollView.backgroundColor = chromeBackground
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.documentView = canvas
    add(pagesSidebar, to: workArea)
    add(scrollView, to: workArea)
    sidebarWidth = pagesSidebar.widthAnchor.constraint(equalToConstant: 0)
    pagesSidebar.isHidden = true
    NSLayoutConstraint.activate([
      sidebarWidth, pagesSidebar.leadingAnchor.constraint(equalTo: workArea.leadingAnchor),
      pagesSidebar.topAnchor.constraint(equalTo: workArea.topAnchor),
      pagesSidebar.bottomAnchor.constraint(equalTo: workArea.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: pagesSidebar.trailingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: workArea.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: workArea.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: workArea.bottomAnchor),
    ])
    pagesSidebar.thumbnail = { [weak self] p in
      guard let self else { return nil }
      return self.canvas.renderer.thumbnail(self.canvas.notebook, page: p)
    }
    pagesSidebar.jump = { [weak self] p in self?.jumpToPage(p) }
    pagesSidebar.reorder = { [weak self] p, t in self?.organize("move", page: p, to: t) }
    pagesSidebar.action = { [weak self] action, p in self?.organize(action, page: p) }
    pin(emptyArea, to: workArea)
    setupEmpty()
  }

  private func setupHeader() {
    let brand = NotebookGlyph(size: 28)
    documentName.lineBreakMode = .byTruncatingMiddle
    documentName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let title = chromeStack([brand, documentName], spacing: 9)
    add(title, to: header)
    statusButton = ChromeButton(
      "Saved", symbol: "checkmark.circle", target: self, action: #selector(saveStatus(_:)))
    statusButton.textColor = chromeMuted
    statusButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    previewButton = ChromeButton(
      "Preview PDF", symbol: "doc.text.magnifyingglass", style: .outlined,
      target: self, action: #selector(previewPDF(_:)))
    exportButton = ChromeButton(
      "Export PDF", symbol: "square.and.arrow.up", style: .primary,
      target: self, action: #selector(exportPDF(_:)))
    solveButton = ChromeButton(
      "Solve", symbol: "function", style: .outlined, target: self, action: #selector(scanPage(_:)))
    canvas.onStudyPick = { [weak self] problem in self?.studyPanel(problem, "") }
    let actions = chromeStack(
      [statusButton, solveButton, previewButton, exportButton], spacing: 8)
    for view in [previewButton!, exportButton!] {
      view.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    add(actions, to: header)
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 86),
      title.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 1),
      actions.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
      title.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
    ])
  }

  private func setupToolbar() {
    let brush = ChromeButton(
      NoteTool.brush.title, symbol: "pencil.tip", shortcut: "Q", target: self,
      action: #selector(brushTool(_:)))
    let selector = ChromeButton(
      "Selector", symbol: "cursorarrow", shortcut: "W", target: self,
      action: #selector(selectorTool(_:)))
    let eraser = ChromeButton(
      "Eraser", symbol: "eraser", shortcut: "E", target: self, action: #selector(eraserTool(_:)))
    let text = ChromeButton(
      "Text", symbol: "textformat", shortcut: "R", target: self, action: #selector(textTool(_:)))
    brush.toolTip = "Writer (Q)"
    selector.toolTip =
      "Selector (W). Drag the selected objects or use the corner handles to resize."
    eraser.toolTip =
      "Eraser (E). Choose Regular, Stroke, Rectangle or Lasso. The upper pen switch erases until tip lift."
    text.toolTip = "Text (R). Click the paper to type. Press Command–Return to finish."
    toolButtons = [.brush: brush, .selector: selector, .eraser: eraser, .text: text]
    let extra: [(NoteTool, String, String)] = [
      (.marker, "highlighter", "Highlighter"), (.shapes, "square.on.circle", "Shapes"),
      (.table, "tablecells", "Table"),
    ]
    let extraButtons = extra.enumerated().map { index, item -> ChromeButton in
      let b = ChromeButton(symbol: item.1, target: self, action: #selector(extraTool(_:)))
      b.tag = index
      b.setAccessibilityLabel(item.2)
      b.toolTip = item.2
      toolButtons[item.0] = b
      return b
    }
    let left = chromeStack(
      [brush, selector, eraser, text] + extraButtons, spacing: 4)
    add(left, to: toolbar)

    colorButtons = InkColor.colors.enumerated().map { index, item in
      let button = ChromeButton(target: self, action: #selector(pickColor(_:)))
      button.tag = index
      button.swatch = item.1.ns
      button.controlWidth = 25
      button.toolTip = item.0
      button.setAccessibilityLabel(item.0)
      return button
    }
    palette = chromeStack(colorButtons, spacing: 0)
    paletteButton = ChromeButton(
      symbol: "paintpalette", target: self, action: #selector(togglePalette(_:)))
    paletteButton.setAccessibilityLabel("Toggle color palette")
    paletteButton.toolTip = "Show or hide ink colors"
    let image = ChromeButton(
      symbol: "photo.badge.plus", target: self, action: #selector(importImage(_:)))
    image.setAccessibilityLabel("Import image")
    image.toolTip = "Import an image. Paste a screenshot with Command–V."
    let settings = ChromeButton(
      symbol: "slider.horizontal.3", target: self, action: #selector(showPenSettings(_:)))
    optionsButton = settings
    settings.setAccessibilityLabel("Writing device and pen settings")
    settings.toolTip = "Writing device and scroll speed"
    let right = chromeStack([palette, paletteButton, separator(), image, settings], spacing: 5)
    add(right, to: toolbar)
    NSLayoutConstraint.activate([
      left.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 13),
      left.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      right.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      right.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -13),
      left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -8),
    ])
  }

  @objc func togglePages(_ sender: Any?) {
    let opening = pagesSidebar.isHidden
    pagesSidebar.isHidden = !opening
    sidebarWidth.constant = opening ? PageSidebar.openWidth : 0
    pagesButton.selected = opening
    workArea.layoutSubtreeIfNeeded()
    resizeCanvas()
    pagesSidebar.update(canvas.notebook, current: page)
  }
  func jumpToPage(_ p: Int) {
    resizeCanvas(minimumPages: p + 2)
    let clip = scrollView.contentView
    clip.scroll(to: CGPoint(x: clip.bounds.minX, y: CGFloat(p) * paperSize.height * canvas.scale))
    scrollView.reflectScrolledClipView(clip)
    updatePage()
    recordPosition()
  }
  func organize(_ action: String, page p: Int, to destination: Int? = nil) {
    canvas.finishText()
    canvas.finishGesture()
    var order: [Int?] = Array(0..<canvas.notebook.usedPages).map { Optional($0) }
    guard order.indices.contains(p) else { return }
    var target = p
    let name: String
    switch action {
    case "insert":
      guard order.count < 99999 else { return }
      target = p + 1
      order.insert(nil, at: target)
      name = "Insert Page"
    case "move":
      guard let destination, order.indices.contains(destination) else { return }
      target = destination
      order.insert(order.remove(at: p), at: target)
      name = "Move Page"
    case "up", "down":
      target = p + (action == "up" ? -1 : 1)
      guard order.indices.contains(target) else { return }
      order.swapAt(p, target)
      name = "Move Page"
    case "delete":
      order.remove(at: p)
      target = max(0, min(p, order.count - 1))
      name = "Delete Page"
    default: return
    }
    canvas.arrangePages(order, name: name)
    jumpToPage(target)
  }
  private func setupFooter() {
    pagesButton = ChromeButton(
      symbol: "sidebar.left", target: self, action: #selector(togglePages(_:)))
    pagesButton.toolTip = "Page thumbnails"
    pagesButton.setAccessibilityLabel("Pages")
    pagesButton.controlWidth = 27
    pagesButton.controlHeight = 24
    selectionActions = ChromeButton(
      "Selection", symbol: "chevron.down", style: .outlined, target: self,
      action: #selector(showSelectionActions(_:)))
    selectionActions.controlHeight = 24
    selectionActions.toolTip = "Copy, delete, or erase handwriting in the selection"
    paperButton = ChromeButton(
      "A4 · Grid", symbol: "chevron.down", target: self, action: #selector(showPaper(_:)))
    paperButton.controlHeight = 25
    paperButton.toolTip = "Page ruling and paper color"
    let clearWriting = ChromeButton("Clear Writing", style: .outlined, target: self,
      action: #selector(clearPage(_:)))
    clearWriting.controlHeight = 24
    clearWriting.setAccessibilityLabel("Clear writing on this page")
    clearWriting.toolTip = "Clear Pen, Brush and Fineliner strokes on this page. Undo with ⌘Z."
    undoButton = ChromeButton(
      symbol: "arrow.uturn.backward", target: self, action: #selector(undoEdit(_:)))
    redoButton = ChromeButton(
      symbol: "arrow.uturn.forward", target: self, action: #selector(redoEdit(_:)))
    for (button, name, key) in [(undoButton!, "Undo", "⌘Z"), (redoButton!, "Redo", "⇧⌘Z")] {
      button.controlHeight = 24
      button.controlWidth = 27
      button.setAccessibilityLabel(name)
      button.toolTip = name + " (" + key + ")"
    }
    let left = chromeStack(
      [
        pagesButton, pageLabel, separator(), paperButton, clearWriting, separator(), undoButton, redoButton,
        selectionActions,
      ],
      spacing: 5)
    add(left, to: footer)
    minZoomButton = ChromeButton(symbol: "minus", target: self, action: #selector(zoomOut(_:)))
    minZoomButton.controlWidth = 26
    minZoomButton.controlHeight = 24
    minZoomButton.setAccessibilityLabel("Zoom out")
    maxZoomButton = ChromeButton(symbol: "plus", target: self, action: #selector(zoomIn(_:)))
    maxZoomButton.controlWidth = 26
    maxZoomButton.controlHeight = 24
    maxZoomButton.setAccessibilityLabel("Zoom in")
    zoomLabel.alignment = .center
    zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    zoomLabel.widthAnchor.constraint(equalToConstant: 39).isActive = true
    fitButton = ChromeButton(
      "Fit Width", symbol: "arrow.left.and.right", style: .outlined, target: self,
      action: #selector(fitWidth(_:)))
    fitButton.controlHeight = 24
    fitButton.toolTip = "Fit Width (Command–0)"
    let zoomControls = chromeStack(
      [minZoomButton, zoomLabel, maxZoomButton, fitButton], spacing: 5)
    add(zoomControls, to: footer)
    NSLayoutConstraint.activate([
      left.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
      left.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
      zoomControls.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -13),
      zoomControls.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])
  }

  private func setupEmpty() {
    let glyph = NotebookGlyph(size: 66)
    let title = chromeLabel("Gridnote", size: 33, weight: .semibold)
    let line = chromeLabel("Write on grid paper or annotate a PDF.", size: 14, color: chromeMuted)
    let new = ChromeButton(
      "New Notebook", symbol: "plus", style: .primary, target: self,
      action: #selector(newNotebook(_:)))
    let open = ChromeButton(
      "Open…", symbol: "folder", style: .outlined, target: self, action: #selector(openAny(_:)))
    new.controlHeight = 35
    open.controlHeight = 35
    deviceLabel = chromeLabel(preferences.deviceDescription, size: 12, color: chromeMuted)
    let row = chromeStack([new, open], spacing: 9)
    let column = chromeStack(
      [glyph, title, line, deviceLabel, row], spacing: 10, horizontal: false)
    column.alignment = .centerX
    column.setCustomSpacing(13, after: glyph)
    column.setCustomSpacing(22, after: line)
    add(column, to: emptyArea)
    NSLayoutConstraint.activate([
      column.centerXAnchor.constraint(equalTo: emptyArea.centerXAnchor),
      column.centerYAnchor.constraint(equalTo: emptyArea.centerYAnchor, constant: -23),
    ])
  }

  private func bindCanvas() {
    canvas.didEdit = { [weak self] in self?.onEdit() }
    canvas.positionDidChange = { [weak self] in
      guard let self, !self.framing else { return }
      self.recordPosition()
    }
    canvas.toolDidChange = { [weak self] in self?.updateTools() }
    canvas.reportError = { [weak self] headline, error in self?.alert(headline, error: error) }
    canvas.scrollBy = { [weak self] amount in self?.penScroll(by: amount) }
    canvas.pinch = { [weak self] amount, location in
      guard let self else { return }
      let anchor =
        self.scrollView.contentView.convert(location, from: nil)
        - self.scrollView.contentView.bounds.origin
      self.setZoom(self.zoom * (1 + amount), around: anchor)
    }
    let clip = scrollView.contentView
    clip.postsBoundsChangedNotifications = true
    clip.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(clipMoved(_:)), name: NSView.boundsDidChangeNotification,
      object: clip)
    NotificationCenter.default.addObserver(
      self, selector: #selector(clipResized(_:)), name: NSView.frameDidChangeNotification,
      object: clip)
    let types: NSEvent.EventTypeMask = [
      .tabletPoint, .tabletProximity, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
      .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseDragged,
      .otherMouseUp, .mouseMoved, .keyDown, .keyUp,
    ]
    monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
      guard let self else { return event }
      return self.canvas.route(event)
    }
    updateTools()
  }

  private func showEmpty() {
    emptyArea.isHidden = false
    scrollView.isHidden = true
    toolbar.isHidden = true
    footer.isHidden = true
    toolbarHeight.constant = 0
    footerHeight.constant = 0
    documentName.stringValue = "Gridnote"
    window?.title = "Gridnote"
    statusButton.isHidden = true
    solveButton.isHidden = true
    previewButton.isHidden = true
    exportButton.isHidden = true
  }

  func restoreLastNotebook() {
    do {
      session = try storage.loadSession()
      if let url = session.lastNotebook {
        try openNotebook(url, recovering: true)
      }
    } catch { alert("Couldn’t reopen the last notebook", error: error) }
  }

  private func showNotebook(
    _ notebook: Notebook, at url: URL, recovered: Bool = false, position: ViewPosition? = nil
  ) {
    framing = true
    scanID = UUID()
    lastScan = nil
    solveButton.isEnabled = true
    solveButton.caption = "Solve"
    solveButton.selected = false
    notebookURL = url
    lastSavedRevision = recovered ? nil : notebook.revision
    notebookSaveError = nil
    let key = url.standardizedFileURL.path
    let target = position ?? session.positions[key] ?? ViewPosition()
    zoom = target.zoom.isFinite ? min(4, max(1, target.zoom)) : 1
    canvas.load(notebook)
    let title = url.deletingPathExtension().lastPathComponent
    documentName.stringValue = title
    documentName.toolTip = url.path
    window?.title = "\(title) — Gridnote"
    emptyArea.isHidden = true
    scrollView.isHidden = false
    toolbar.isHidden = false
    footer.isHidden = false
    toolbarHeight.constant = 47
    footerHeight.constant = 34
    statusButton.isHidden = false
    solveButton.isHidden = false
    previewButton.isHidden = false
    exportButton.isHidden = false
    window?.contentView?.layoutSubtreeIfNeeded()
    let origin = CGPoint(
      x: target.x.isFinite ? max(0, target.x) : 0,
      y: target.y.isFinite ? min(paperSize.height * 100_000, max(0, target.y)) : 0)
    resizeCanvas(at: origin)
    window?.makeFirstResponder(canvas)
    canvas.restoreInteraction(target)
    framing = false
    session.lastNotebook = url
    hasSessionChanges = true
    recordPosition()
    saveSession()
    updateTools()
    updateStatus(recovered ? "Recovered" : nil)
    if recovered { onEdit() }
  }

  private func openNotebook(_ url: URL, recovering: Bool = false) throws {
    let canonical = url.standardizedFileURL
    if canonical == notebookURL { return }
    guard commitCurrent() else { return }
    let file = try storage.open(canonical, recovering: recovering)
    showNotebook(file.notebook, at: canonical, recovered: file.recovered)
  }

  func openFile(_ file: URL) {
    do {
      if file.pathExtension.lowercased() == "pdf" {
        try openPDF(file)
      } else {
        try openNotebook(file, recovering: true)
      }
    } catch { alert("Couldn’t open \(file.lastPathComponent)", error: error) }
  }

  private func openPDF(_ file: URL) throws {
    guard commitCurrent() else { return }
    let data = try Data(contentsOf: file)
    guard let pdf = PaperRenderer(pdfData: data).pdf else {
      throw StorageError("The file couldn’t be read as a PDF.")
    }
    guard !pdf.isEncrypted || pdf.isUnlocked else {
      throw StorageError("Unlock the PDF before importing it.")
    }
    guard pdf.numberOfPages > 0 else { throw StorageError("The PDF has no pages.") }
    var background = data
    if let document = PDFDocument(data: data),
      (0..<document.pageCount).contains(where: {
        document.page(at: $0)?.annotations.isEmpty == false
      })
    {
      guard
        let flattened = document.dataRepresentation(options: [
          PDFDocumentWriteOption.burnInAnnotationsOption: true
        ])
      else {
        throw StorageError("The existing PDF annotations could not be imported.")
      }
      background = flattened
    }
    let notebook = Notebook(sourcePDF: background, sourcePages: pdf.numberOfPages)
    let url = try storage.localURL(named: file.deletingPathExtension().lastPathComponent)
    try storage.saveNow(notebook, to: url)
    showNotebook(notebook, at: url, position: ViewPosition())
  }

  @objc func newNotebook(_ sender: Any?) {
    settingsPopover?.performClose(nil)
    do {
      guard commitCurrent() else { return }
      let url = try storage.localURL(named: "Untitled Notebook")
      let notebook = Notebook()
      try storage.saveNow(notebook, to: url)
      showNotebook(notebook, at: url, position: ViewPosition())
    } catch { alert("Couldn’t create a notebook", error: error) }
  }

  @objc func openAny(_ sender: Any?) {
    settingsPopover?.performClose(nil)
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.gridnote, .pdf]
    panel.directoryURL = notebookURL?.deletingLastPathComponent()
    panel.message = "Open an editable Gridnote notebook or a PDF to annotate."
    panel.beginSheetModal(for: window!) { [weak self] response in
      if response == .OK, let url = panel.url { self?.openFile(url) }
    }
  }

  @objc func saveNow(_ sender: Any?) { _ = checkpoint(force: true) }

  @objc func saveAs(_ sender: Any?) {
    guard let notebookURL else { return }
    canvas.finishText()
    canvas.finishGesture()
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.gridnote]
    panel.nameFieldStringValue = notebookURL.deletingPathExtension().lastPathComponent
    panel.directoryURL = .documentsDirectory
    panel.beginSheetModal(for: window!) { [weak self] response in
      guard let self, response == .OK, let location = panel.url?.standardizedFileURL else { return }
      do {
        let position = self.viewPosition
        let notebook = self.canvas.notebook
        try self.storage.saveNow(notebook, to: location)
        if location == notebookURL {
          self.lastSavedRevision = notebook.revision
          self.notebookSaveError = nil
          self.updateStatus()
        } else {
          self.showNotebook(notebook, at: location, position: position)
        }
      } catch { self.alert("Couldn’t save the notebook", error: error) }
    }
  }

  private func onEdit() {
    lastScan = nil
    guard let url = notebookURL else { return }
    updatePage()
    updateHistory()
    solveButton?.selected = false
    if canvas.notebook.usedPages >= canvas.pageCount { resizeCanvas() }
    updateStatus()
    storage.schedule(canvas.saveSnapshot, to: url) { [weak self] revision, result in
      guard let self, self.notebookURL == url, self.canvas.notebook.revision >= revision else {
        return
      }
      if let last = self.lastSavedRevision, last > revision { return }
      switch result {
      case .success:
        self.lastSavedRevision = revision
        self.notebookSaveError = nil
      case .failure(let error): self.notebookSaveError = error
      }
      self.updateStatus()
    }
  }

  @discardableResult func commitCurrent(force: Bool = false, showError: Bool = true) -> Bool {
    canvas.finishText()
    return checkpoint(force: force, showError: showError)
  }

  @discardableResult func checkpoint(force: Bool = false, showError: Bool = true) -> Bool {
    canvas.resetInputForFocus()
    recordPosition()
    saveSession()
    guard let notebookURL else { return true }
    if !force, notebookSaveError == nil, lastSavedRevision == canvas.notebook.revision {
      return true
    }
    do {
      try storage.saveNow(canvas.saveSnapshot, to: notebookURL)
      lastSavedRevision = canvas.notebook.revision
      notebookSaveError = nil
      updateStatus()
      return true
    } catch {
      notebookSaveError = error
      updateStatus()
      if showError { alert("Couldn’t finish saving", error: error) }
      return false
    }
  }

  private func updateStatus(_ override: String? = nil) {
    guard statusButton != nil, notebookURL != nil else { return }
    if let error = notebookSaveError ?? sessionSaveError {
      statusButton.caption = "Save Error"
      statusButton.symbol = "exclamationmark.circle"
      statusButton.textColor = chromeWarning
      statusButton.toolTip = error.localizedDescription
    } else if let override {
      statusButton.caption = override
      statusButton.symbol = "clock.arrow.circlepath"
      statusButton.textColor = appAccent
      statusButton.toolTip = "Opened from the latest recovery copy"
    } else {
      let complete = canvas.notebook.revision == lastSavedRevision
      statusButton.caption = complete ? "Saved" : "Saving…"
      statusButton.symbol = complete ? "checkmark.circle" : "clock"
      statusButton.textColor = chromeMuted
      statusButton.toolTip = complete ? "Saved locally. Click to save now." : "Saving locally"
    }
  }

  @objc private func saveStatus(_ sender: Any?) {
    if let error = notebookSaveError ?? sessionSaveError {
      let panel = NSAlert()
      panel.messageText = "Gridnote couldn’t finish saving"
      panel.informativeText = error.localizedDescription
      panel.addButton(withTitle: "Retry Save")
      panel.addButton(withTitle: "Close")
      panel.beginSheetModal(for: window!) { [weak self] response in
        if response == .alertFirstButtonReturn { self?.saveNow(nil) }
      }
    } else {
      saveNow(nil)
    }
  }

  private var viewPosition: ViewPosition {
    let origin = scrollView.contentView.bounds.origin
    let scale = max(0.001, canvas.scale)
    var value = ViewPosition(zoom: zoom, x: max(0, origin.x / scale), y: max(0, origin.y / scale))
    canvas.rememberInteraction(in: &value)
    return value
  }

  private func recordPosition() {
    guard let key = notebookURL?.standardizedFileURL.path else { return }
    let position = viewPosition
    guard position != session.positions[key] else { return }
    session.positions[key] = position
    hasSessionChanges = true
    if sessionTimer == nil {
      let timer = Timer(timeInterval: 0.16, repeats: false) { [weak self] _ in self?.saveSession() }
      sessionTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func saveSession() {
    sessionTimer?.invalidate()
    sessionTimer = nil
    guard hasSessionChanges else { return }
    do {
      try storage.saveSession(session)
      hasSessionChanges = false
      sessionSaveError = nil
    } catch { sessionSaveError = error }
    updateStatus()
  }

  @objc private func clipMoved(_ notification: Notification) {
    guard !framing, notebookURL != nil else { return }
    let clip = scrollView.contentView
    if clip.bounds.maxY > canvas.frame.height - clip.bounds.height * 0.55 {
      resizeCanvas(minimumPages: canvas.pageCount + 2)
    }
    updatePage()
    recordPosition()
  }

  @objc private func clipResized(_ notification: Notification) {
    guard !framing, notebookURL != nil else { return }
    if abs(lastLayoutWidth - scrollView.contentView.bounds.width) > 0.01 { resizeCanvas() }
    updatePage()
    recordPosition()
  }

  private func resizeCanvas(at origin: CGPoint? = nil, minimumPages: Int = 0) {
    let clip = scrollView.contentView
    let width = clip.bounds.width
    guard width > 1, clip.bounds.height > 1 else { return }
    let position = viewPosition
    let desired = origin ?? CGPoint(x: position.x, y: position.y)
    let scale = width / paperSize.width * zoom
    let visiblePages = (desired.y + clip.bounds.height / scale) / paperSize.height
    let count = max(
      2,
      min(
        100_002,
        max(
          canvas.pageCount, canvas.notebook.usedPages + 1, minimumPages, Int(ceil(visiblePages)) + 1
        )))
    let wasFraming = framing
    framing = true
    lastLayoutWidth = width
    canvas.sizing(width: width * zoom, pages: count)
    moveClip(to: desired * scale)
    framing = wasFraming
    updatePage()
    if !framing { recordPosition() }
  }

  private func moveClip(to point: CGPoint) {
    let clip = scrollView.contentView
    let constrained = clip.constrainBoundsRect(CGRect(origin: point, size: clip.bounds.size))
    clip.scroll(to: constrained.origin)
    scrollView.reflectScrolledClipView(clip)
    window?.invalidateCursorRects(for: canvas)
  }

  private func penScroll(by delta: CGFloat) {
    let clip = scrollView.contentView
    let origin = clip.bounds.origin
    if origin.y + clip.bounds.height + max(delta, 0) > canvas.frame.height - clip.bounds.height
      * 0.55
    {
      resizeCanvas(minimumPages: canvas.pageCount + 2)
    }
    moveClip(to: CGPoint(x: origin.x, y: origin.y + delta))
  }

  private func setZoom(_ requested: CGFloat, around anchor: CGPoint? = nil) {
    guard notebookURL != nil else { return }
    let proposed = min(4, max(1, requested))
    guard abs(proposed - zoom) > 0.001 else { return }
    let clip = scrollView.contentView
    let anchor = anchor ?? CGPoint(x: clip.bounds.width / 2, y: clip.bounds.height / 2)
    let oldScale = max(0.001, canvas.scale)
    let newScale = clip.bounds.width / paperSize.width * proposed
    let origin = (clip.bounds.origin + anchor) * (1 / oldScale) - anchor * (1 / newScale)
    zoom = proposed
    resizeCanvas(at: CGPoint(x: max(0, origin.x), y: max(0, origin.y)))
    updateTools()
  }

  private func updatePage() {
    let visible = canvas.visibleRect
    let focusY = max(0, visible.minY + min(visible.height * 0.24, 85))
    let nextPage = max(0, min(canvas.pageCount - 1, Int(floor(focusY / paperSize.height))))
    if nextPage != page, !canvas.studyProblems.isEmpty {
      canvas.studyProblems = []
      solveButton.selected = false
      if settingsPopover?.contentViewController is StudyPanel { settingsPopover?.performClose(nil) }
    }
    page = nextPage
    pagesSidebar.update(canvas.notebook, current: page)
    pageLabel.stringValue = "Page \(page + 1)"
    paperButton?.caption =
      "A4 · "
      + (canvas.notebook.sourceIndex(on: page) != nil
        ? "PDF" : canvas.notebook.paper(on: page).ruling.rawValue)
  }

  @objc func zoomIn(_ sender: Any?) { setZoom(zoom * 1.22) }
  @objc func zoomOut(_ sender: Any?) { setZoom(zoom / 1.22) }
  @objc func fitWidth(_ sender: Any?) { setZoom(1) }

  @objc private func extraTool(_ sender: NSButton) {
    activate([.marker, .shapes, .table][sender.tag], sender: sender)
  }
  @objc func brushTool(_ sender: Any?) { activate(.brush, sender: sender) }
  @objc func selectorTool(_ sender: Any?) { activate(.selector, sender: sender) }
  @objc func eraserTool(_ sender: Any?) { activate(.eraser, sender: sender) }
  @objc func textTool(_ sender: Any?) { activate(.text, sender: sender) }
  private func activate(_ tool: NoteTool, sender: Any?) {
    canvas.chooseTool(tool)
    guard sender != nil, let button = toolButtons[tool] else { return }
    settingsPopover?.performClose(nil)
    let panel = ToolOptionsController(tool: tool, canvas: canvas)
    panel.didInsert = { [weak self] in self?.settingsPopover?.performClose(nil) }
    panel.didRestore = { [weak self, weak button] in self?.activate(tool, sender: button) }
    _ = panel.view
    let popover = NSPopover()
    popover.behavior = .transient
    popover.appearance = NSAppearance(named: .darkAqua)
    popover.contentViewController = panel
    popover.contentSize = panel.preferredContentSize
    let anchor = sender as? NSView ?? button
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    settingsPopover = popover
  }

  @objc func clearPage(_ sender: Any?) { canvas.clearWriting(.handwriting, on: page) }
  @objc func clearPageText(_ sender: Any?) { canvas.clearWriting(.typedText, on: page) }
  @objc func clearTypedText(_ sender: Any?) { canvas.clearWriting(.typedText) }
  @objc func clearAll(_ sender: Any?) { canvas.clearWriting(.handwriting) }
  @objc func deletePage(_ sender: Any?) { canvas.deletePage(page) }

  private func updateTools() {
    guard palette != nil, fitButton != nil else { return }
    updateHistory()
    if !pagesSidebar.isHidden { pagesSidebar.update(canvas.notebook, current: page) }
    solveButton?.isEnabled = canvas.active && solveButton.caption != "Scanning…"
    solveButton?.selected = !canvas.studyProblems.isEmpty
    for (tool, button) in toolButtons {
      let appearance = preferences.toolAppearance(tool)
      if button.symbol != appearance.symbol { button.symbol = appearance.symbol }
      let family = tool.title
      let detail = tool == .marker ? markerColors[preferences.markerIndex].0 : appearance.name
      let label = family == detail ? family : family + " · " + detail
      button.toolTip = label + (button.shortcut.map { " (" + $0 + ")" } ?? "")
      if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
      if tool == .marker { button.textColor = markerColors[preferences.markerIndex].1.ns }
      button.selected = tool == canvas.effectiveTool
    }
    selectionActions.isHidden = canvas.effectiveTool != .selector || !canvas.hasSelection
    selectionActions.caption = "\(canvas.selectionCount) selected"
    let compact = (window?.frame.width ?? 1000) < 900
    for (tool, b) in toolButtons where [.brush, .selector, .eraser, .text].contains(tool) {
      let name = compact ? "" : tool.title
      if b.caption != name {
        b.caption = name
        b.setAccessibilityLabel(b.toolTip ?? tool.title)
      }
    }
    palette.isHidden = !preferences.paletteVisible
    paletteButton.selected = preferences.paletteVisible
    for (index, button) in colorButtons.enumerated() {
      let marker = canvas.effectiveTool == .marker
      let item = (marker ? markerColors : InkColor.colors)[index]
      button.swatch = item.1.ns
      button.toolTip = item.0
      button.setAccessibilityLabel(item.0)
      button.selected =
        index
        == (marker
          ? preferences.markerIndex
          : canvas.effectiveTool == .text
            ? InkColor.colors.firstIndex(where: { $0.1 == canvas.currentFormat(table: false).color }
            ) : preferences.colorIndex)
    }
    zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
    minZoomButton.isEnabled = zoom > 1.001
    maxZoomButton.isEnabled = zoom < 3.999
    fitButton.selected = zoom <= 1.001
  }

  @objc private func showSelectionActions(_ sender: NSView) {
    let menu = NSMenu()
    for (title, action) in [
      ("Copy", #selector(NoteCanvas.copy(_:))),
      ("Erase Selected Strokes", #selector(NoteCanvas.eraseSelectedStrokes(_:))),
      ("Delete Selection", #selector(NoteCanvas.delete(_:))),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = canvas
      menu.addItem(item)
    }
    if canvas.selectedImageIndex != nil {
      let item = menu.addItem(
        withTitle: "Fit Image to Page", action: #selector(NoteCanvas.fitSelectedImage(_:)),
        keyEquivalent: "")
      item.target = canvas
    }
    menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }

  @objc func selectByTap(_ sender: Any?) {
    canvas.selectMode = .tap
    selectWithCurrentMode()
  }
  @objc func selectByRectangle(_ sender: Any?) {
    canvas.selectMode = .box
    selectWithCurrentMode()
  }
  @objc func selectByLasso(_ sender: Any?) {
    canvas.selectMode = .lasso
    selectWithCurrentMode()
  }
  private func selectWithCurrentMode() { canvas.chooseTool(.selector) }

  @objc func togglePalette(_ sender: Any?) {
    preferences.paletteVisible.toggle()
    updateTools()
  }

  @objc private func pickColor(_ sender: NSButton) {
    if canvas.effectiveTool == .text {
      if canvas.editor != nil { canvas.chooseTool(.text) }
      canvas.changeFormat(table: false) { $0.color = InkColor.colors[sender.tag].1 }
      canvas.refreshTool()
    } else if canvas.effectiveTool == .marker {
      preferences.markerIndex = sender.tag
      canvas.refreshTool()
    } else {
      preferences.colorIndex = sender.tag
      canvas.chooseTool(canvas.effectiveTool == .shapes ? .shapes : .brush)
    }
  }

  @objc func importImage(_ sender: Any?) {
    guard notebookURL != nil else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = true
    panel.beginSheetModal(for: window!) { [weak self] response in
      if response == .OK { for url in panel.urls { self?.canvas.importImage(from: url) } }
    }
  }

  @objc private func showPaper(_ sender: NSView) {
    settingsPopover?.performClose(nil)
    let panel = PaperPicker(canvas: canvas, page: page)
    let popover = NSPopover()
    popover.behavior = .transient
    popover.appearance = NSAppearance(named: .darkAqua)
    popover.contentViewController = panel
    popover.contentSize = panel.preferredContentSize
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    settingsPopover = popover
  }

  @objc func openOptions(_ sender: Any?) {
    if let button = optionsButton { showPenSettings(button) }
  }
  @objc private func showPenSettings(_ sender: NSView) {
    if settingsPopover?.isShown == true {
      settingsPopover?.performClose(nil)
      return
    }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.appearance = NSAppearance(named: .darkAqua)
    let pane = PenSettingsController(preferences: preferences) { [weak self, weak popover] in
      popover?.performClose(nil)
      self?.wacomSetup(nil)
    }
    pane.didRestore = { [weak self] in self?.canvas.refreshTool() }
    popover.contentViewController = pane
    popover.contentSize = pane.preferredContentSize
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    settingsPopover = popover
  }

  @objc func quickGuide(_ sender: Any?) {
    if let url = Bundle.main.url(forResource: "guide", withExtension: "html") {
      NSWorkspace.shared.open(url)
    }
  }
  @objc func markerTool(_ sender: Any?) { activate(.marker, sender: nil) }
  @objc func shapesTool(_ sender: Any?) { activate(.shapes, sender: nil) }
  @objc func tableTool(_ sender: Any?) { activate(.table, sender: nil) }
  @objc func wacomSetup(_ sender: Any?) {
    let box = NSAlert()
    box.messageText = preferences.device.title
    box.informativeText = preferences.device.setup
    box.addButton(withTitle: "Done")
    box.beginSheetModal(for: window!)
  }

  private var editingHistory: UndoManager {
    return canvas.editor?.undoManager ?? canvas.history
  }

  private func updateHistory() {
    let manager = editingHistory
    undoButton?.isEnabled = manager.canUndo
    redoButton?.isEnabled = manager.canRedo
  }

  @objc func undoEdit(_ sender: Any?) {
    editingHistory.undo()
    updateHistory()
  }

  @objc func redoEdit(_ sender: Any?) {
    editingHistory.redo()
    updateHistory()
  }

  @objc func notebookLauncher(_ sender: Any?) { requestLauncher?() }

  func popoverWillClose(_ notification: Notification) {
    if let closing = notification.object as? NSPopover, closing === settingsPopover {
      (closing.contentViewController as? StudyPanel)?.cancelAI()
      if closing.contentViewController is StudyPanel && canvas.studyProblems.count == 1 {
        canvas.studyProblems = []
        solveButton.selected = false
      }
      settingsPopover = nil
      updateHistory()
    }
  }
  @objc private func scanPage(_ sender: Any?) {
    guard canvas.active else { return }
    canvas.finishText()
    canvas.finishGesture()
    let wasShowingResults = !canvas.studyProblems.isEmpty
    settingsPopover?.performClose(nil)
    let id = UUID()
    scanID = id
    if wasShowingResults {
      canvas.studyProblems = []
      solveButton.selected = false
      return
    }
    solveButton.isEnabled = false
    solveButton.caption = "Scanning…"
    let value = canvas.notebook
    let tool = canvas.tool
    let index = page
    let complete: ([StudyProblem], String?) -> Void = { [weak self] items, error in
      guard let self, self.scanID == id else { return }
      self.solveButton.isEnabled = true
      self.solveButton.caption = "Solve"
      guard self.page == index, self.canvas.tool == tool, self.canvas.notebook.id == value.id,
        self.canvas.notebook.revision == value.revision else { return }
      if error == nil { self.lastScan = (value.id, value.revision, index, items) }
      self.canvas.studyProblems = items
      self.solveButton.selected = !items.isEmpty
      if items.isEmpty {
        self.studyPanel(nil, error ?? "No supported problem found on this page. Type an equation, or add a code block in Text options.")
      } else if items.count == 1 {
        self.studyPanel(items[0], "")
      } else {
        self.solveButton.toolTip = "Click a highlighted exercise. Click Solve again to leave."
      }
    }
    if let cached = lastScan, cached.id == value.id, cached.revision == value.revision, cached.page == index {
      complete(cached.problems, nil)
    } else {
      studySolver.candidates(value, page: index, done: complete)
    }
  }
  private func studyPanel(_ problem: StudyProblem?, _ message: String) {
    settingsPopover?.performClose(nil)
    let controller = StudyPanel(solver: studySolver, problem: problem, message: message)
    _ = controller.view
    let panel = NSPopover()
    panel.behavior = .transient
    panel.appearance = NSAppearance(named: .darkAqua)
    controller.keepOpenDuringSignIn = { [weak panel] keep in panel?.behavior = keep ? .applicationDefined : .transient }
    panel.contentViewController = controller
    panel.contentSize = controller.preferredContentSize
    panel.delegate = self
    if let problem, problem.frame.intersects(canvas.visibleRect) {
      panel.show(
        relativeTo: problem.frame.intersection(canvas.visibleRect), of: canvas, preferredEdge: .maxX
      )
    } else {
      panel.show(relativeTo: solveButton.bounds, of: solveButton, preferredEdge: .minY)
    }
    settingsPopover = panel
  }
  @objc func previewPDF(_ sender: Any?) { preparePDF(showingPreview: true) }
  @objc func exportPDF(_ sender: Any?) { preparePDF(showingPreview: false) }

  private func preparePDF(showingPreview: Bool) {
    guard notebookURL != nil, !preparingPDF, window?.attachedSheet == nil else { return }
    canvas.finishText()
    canvas.finishGesture()
    let notebook = canvas.notebook
    let startPage = page
    let filename =
      notebookURL!.deletingPathExtension().lastPathComponent
      + (notebook.sourcePDF == nil ? "" : " - Annotated")
    preparingPDF = true
    previewButton.isEnabled = false
    exportButton.isEnabled = false
    let button = showingPreview ? previewButton! : exportButton!
    let originalCaption = button.caption
    button.caption = "Preparing…"
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let data = Result { try PaperRenderer(pdfData: notebook.sourcePDF).export(notebook) }
      DispatchQueue.main.async {
        guard let self else { return }
        self.preparingPDF = false
        self.previewButton.isEnabled = true
        self.exportButton.isEnabled = true
        button.caption = originalCaption
        switch data {
        case .success(let bytes):
          if showingPreview {
            self.presentPreview(bytes, filename: filename, page: startPage)
          } else {
            self.savePDF(bytes, filename: filename)
          }
        case .failure(let error): self.alert("Couldn’t prepare the PDF", error: error)
        }
      }
    }
  }

  private func presentPreview(_ data: Data, filename: String, page: Int) {
    guard let window,
      let preview = PDFPreviewController(
        data: data, parentSize: window.frame.size, page: page,
        name: notebookURL?.deletingPathExtension().lastPathComponent ?? "Notebook")
    else { return }
    self.preview = preview
    preview.onClose = { [weak self] exporting in
      guard let self, let panel = self.preview?.window else { return }
      self.window?.endSheet(panel, returnCode: exporting ? .OK : .cancel)
    }
    window.beginSheet(preview.window!) { [weak self] response in
      self?.preview = nil
      if response == .OK { DispatchQueue.main.async { self?.savePDF(data, filename: filename) } }
    }
  }

  private func savePDF(_ data: Data, filename: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = filename + ".pdf"
    panel.directoryURL = .documentsDirectory
    panel.beginSheetModal(for: window!) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do { try data.write(to: url, options: .atomic) } catch {
        self?.alert("Couldn’t export the PDF", error: error)
      }
    }
  }

  private func alert(_ headline: String, error: Error) {
    guard let window else { return }
    let alert = NSAlert(error: error)
    alert.messageText = headline
    alert.informativeText = error.localizedDescription
    if window.isVisible, window.attachedSheet == nil {
      alert.beginSheetModal(for: window)
    } else if let sheet = window.attachedSheet {
      alert.beginSheetModal(for: sheet)
    } else {
      alert.runModal()
    }
  }

  func windowDidResize(_ notification: Notification) { if palette != nil { updateTools() } }
  func windowDidResignKey(_ notification: Notification) {
    canvas.resetInputForFocus()
    saveSession()
  }
  func windowDidBecomeKey(_ notification: Notification) {
    preferences.detectDevice()
    deviceLabel?.stringValue = preferences.deviceDescription
    canvas.resetInputForFocus()
  }
  func windowWillEnterFullScreen(_ notification: Notification) {
    canvas.resetInputForFocus()
    canvas.finishText()
  }
  func windowWillExitFullScreen(_ notification: Notification) {
    canvas.resetInputForFocus()
    canvas.finishText()
  }
  func windowDidEnterFullScreen(_ notification: Notification) {
    resizeCanvas()
    window?.makeFirstResponder(canvas)
  }
  func windowDidExitFullScreen(_ notification: Notification) {
    resizeCanvas()
    window?.makeFirstResponder(canvas)
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { checkpoint() }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(newNotebook(_:)), #selector(openAny(_:)), #selector(notebookLauncher(_:)), #selector(wacomSetup(_:)),
      #selector(quickGuide(_:)):
      return true
    case #selector(deletePage(_:)): return notebookURL != nil && page < canvas.notebook.usedPages
    case #selector(undoEdit(_:)): return editingHistory.canUndo
    case #selector(redoEdit(_:)): return editingHistory.canRedo
    case #selector(previewPDF(_:)), #selector(exportPDF(_:)):
      return notebookURL != nil && !preparingPDF
    case #selector(zoomOut(_:)), #selector(fitWidth(_:)): return notebookURL != nil && zoom > 1.001
    case #selector(zoomIn(_:)): return notebookURL != nil && zoom < 3.999
    default: return notebookURL != nil
    }
  }
}
