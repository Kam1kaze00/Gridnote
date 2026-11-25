import AppKit
import PDFKit
import WebKit

@main struct Smoke {
  static var checks = 0
  static func expect(_ state: @autoclosure () -> Bool, _ name: String) {
    guard state() else {
      fputs("FAIL  \(name)\n", stderr)
      exit(1)
    }
    checks += 1
    print("PASS  \(name)")
  }
  static func pump(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
      while let event = NSApp.nextEvent(
        matching: .any, until: Date(), inMode: .default, dequeue: true)
      { NSApp.sendEvent(event) }
      RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.01)))
    }
  }
  static func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    let qa = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let directory = qa.appendingPathComponent("session-" + UUID().uuidString, isDirectory: true)
    let defaults = UserDefaults(suiteName: "gridnote.qa." + UUID().uuidString)!
    let preferences = PenPreferences(defaults: defaults)
    let brushSymbols = ["Pen", "Brush", "Fineliner"].map { tip in
      preferences.nib = tip
      return preferences.toolAppearance(.brush).symbol
    }
    expect(Set(brushSymbols).count == 3, "each writing tip has its own toolbar symbol")
    let eraseSymbols = EraseMode.allCases.map { mode in
      preferences.eraseMode = mode
      return preferences.toolAppearance(.eraser).symbol
    }
    expect(Set(eraseSymbols).count == 4, "each eraser mode has its own toolbar symbol")
    preferences.showLauncher = true
    expect(PenPreferences(defaults: defaults).showLauncher, "startup launcher preference persists")
    preferences.restore()
    let storage = NotebookStorage(directory: directory)
    let pb = NSPasteboard.withUniqueName()
    let owner = NotebookWindow(storage: storage, preferences: preferences, clipboard: pb)
    let win = owner.window!
    let canvas = owner.canvas
    GridnoteDelegate.installMenus(owner)
    NSApp.finishLaunching()
    win.setFrame(CGRect(x: 60, y: 40, width: 1024, height: 700), display: true)
    NSApp.activate(ignoringOtherApps: true)
    owner.showWindow(nil)
    win.makeKeyAndOrderFront(nil)
    pump(0.1)
    owner.restoreLastNotebook()
    expect(
      owner.notebookURL == nil && !FileManager.default.fileExists(atPath: directory.path),
      "first launch creates no notebook")
    owner.newNotebook(nil)
    pump(0.1)
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(canvas)
    pump(0.15)
    let file = owner.notebookURL!
    expect(
      canvas.notebook.objects.isEmpty && canvas.notebook.usedPages == 1,
      "explicit New creates one blank A4 page")
    expect(
      abs(canvas.frame.width - owner.scrollView.contentView.bounds.width) < 1,
      "Fit Width reaches both sides")

    func send(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) {
      let location = canvas.convert(point, to: nil)
      var event = NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: win.windowNumber, context: nil, eventNumber: 1,
        clickCount: clicks, pressure: 0.7)!
      if [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(type) {
        let cg = event.cgEvent!
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        event = NSEvent(cgEvent: cg)!
      }
      if let passed = canvas.route(event) {
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: passed)
        case .leftMouseDragged: canvas.mouseDragged(with: passed)
        case .leftMouseUp: canvas.mouseUp(with: passed)
        default: break
        }
      }
    }
    func stroke(_ coordinates: [(CGFloat, CGFloat)]) {
      let points = coordinates.map { CGPoint(x: $0.0, y: $0.1) }
      send(.leftMouseDown, points.first!)
      for p in points.dropFirst() { send(.leftMouseDragged, p) }
      send(.leftMouseUp, points.last!)
    }
    func key(_ char: String, _ code: UInt16) -> NSEvent? {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: win.windowNumber, context: nil, characters: char,
        charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: code)!
      return canvas.route(event)
    }
    let data = try Data(contentsOf: qa.appendingPathComponent("exercise.png"))
    pb.clearContents()
    pb.setData(data, forType: .png)
    expect(
      win.firstResponder === canvas
        && win.firstResponder?.tryToPerform(#selector(NoteCanvas.paste(_:)), with: nil) == true,
      "Paste routes through the notebook window’s first responder")
    expect(
      canvas.notebook.objects.count == 1 && canvas.effectiveTool == .selector,
      "pasted screenshot is a movable selected object")
    let imageID = canvas.notebook.objects[0].id
    _ = key("q", 12)
    stroke([(90, 168), (108, 172), (114, 166), (131, 179), (144, 160)])
    let firstInk = canvas.notebook.objects.last!
    stroke([(155, 177), (176, 177)])
    stroke([(180, 177)])
    expect(
      canvas.notebook.objects.count == 4 && canvas.effectiveTool == .brush,
      "brush records quick strokes and a single dot")
    send(.rightMouseDown, CGPoint(x: 98, y: 169))
    send(.rightMouseUp, CGPoint(x: 98, y: 169))
    expect(canvas.effectiveTool == .eraser, "top tap remains armed after button release")
    send(.leftMouseUp, CGPoint(x: 98, y: 169))
    expect(
      canvas.effectiveTool == .eraser,
      "a synthetic hover release cannot consume the one-contact eraser")
    stroke([(99, 170), (102, 170)])
    expect(
      canvas.effectiveTool == .brush
        && !canvas.notebook.objects.contains(where: { $0.id == firstInk.id })
        && canvas.notebook.objects.count == 3,
      "tip lift returns to Brush after deleting one whole stroke")
    owner.undoEdit(nil)
    expect(canvas.notebook.objects.contains(firstInk), "erasing undoes in one operation")
    owner.redoEdit(nil)
    expect(!canvas.notebook.objects.contains(firstInk), "erasing redoes")
    owner.undoEdit(nil)
    _ = key("r", 15)
    preferences.textAlignment = .natural
    stroke([(83, 217)])
    guard let editor = canvas.editor else {
      expect(false, "text editor opens")
      return
    }
    for (char, code): (String, UInt16) in [("q", 12), ("w", 13), ("e", 14), ("r", 15)] {
      guard let e = key(char, code) else {
        expect(false, "canvas swallowed text shortcut")
        return
      }
      editor.interpretKeyEvents([e])
    }
    expect(editor.string == "qwer", "Q, W, E and R type normally inside text")
    editor.insertText("  v = 6 m/s", replacementRange: editor.selectedRange())
    pump(0.45)
    let draft = try storage.open(file).notebook
    expect(draft.objects.count == 5, "active text is autosaved while its editor stays open")
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    expect(
      owner.checkpoint() && canvas.editor?.selectedRange().location == 2,
      "background save keeps the live editor and caret")
    let savedSession = try storage.loadSession()
    expect(
      savedSession.positions[file.standardizedFileURL.path]?.caret == 2,
      "text caret saved for reopening")
    canvas.finishText()
    owner.selectByRectangle(nil)
    stroke([(30, 20), (550, 275)])
    expect(canvas.selectionCount == 5, "rectangle selects handwriting, text and image together")
    canvas.eraseSelectedStrokes(nil)
    expect(
      canvas.notebook.objects.count == 2
        && canvas.notebook.objects.contains(where: { $0.id == imageID }),
      "erase selected strokes preserves text and images")
    owner.undoEdit(nil)
    owner.selectByLasso(nil)
    stroke([(148, 160), (192, 162), (194, 185), (148, 189), (148, 160)])
    expect(canvas.selectionCount == 2, "closed freehand lasso selects the intended marks")
    let beforeMove = canvas.notebook.objects
    stroke([(165, 177), (177, 190)])
    expect(beforeMove != canvas.notebook.objects, "drag moves a group")
    owner.undoEdit(nil)
    owner.selectByTap(nil)
    stroke([(110, 170)])
    expect(canvas.selectionCount == 1, "tap selects a single ink object")
    canvas.copy(nil)
    canvas.paste(nil)
    expect(canvas.notebook.objects.count == 6, "copy and paste keep ink editable")
    canvas.delete(nil)
    expect(canvas.notebook.objects.count == 5, "delete removes the selected object")
    owner.selectByTap(nil)
    let imageFrame = canvas.notebook.objects[0].frame
    stroke([(imageFrame.midX, imageFrame.midY)])
    let pad = 4 / canvas.scale
    stroke([
      (imageFrame.maxX + pad, imageFrame.maxY + pad), (imageFrame.maxX - 50, imageFrame.maxY - 8),
    ])
    expect(
      canvas.notebook.objects[0].frame.width < imageFrame.width - 1,
      "corner handle resizes a selected image")
    owner.undoEdit(nil)
    owner.eraserTool(nil)
    preferences.eraseMode = .box
    stroke([(148, 160), (193, 190)])
    expect(
      canvas.notebook.objects.count == 3, "eraser rectangle removes whole intersecting strokes")
    owner.undoEdit(nil)
    preferences.eraseMode = .stroke
    owner.clearPage(nil)
    expect(
      canvas.notebook.objects.count == 1 && canvas.notebook.objects[0].id == imageID,
      "page cleanup keeps pasted images")
    owner.undoEdit(nil)
    expect(canvas.notebook.objects.count == 5, "page cleanup is undoable")
    owner.brushTool(nil)
    let screen = win.contentView!
    func capture(_ name: String) throws {
      screen.layoutSubtreeIfNeeded()
      screen.displayIfNeeded()
      guard let bitmap = screen.bitmapImageRepForCachingDisplay(in: screen.bounds) else { return }
      screen.cacheDisplay(in: screen.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(
        to: qa.appendingPathComponent(name))
    }
    try capture("notebook.png")
    for tool in NoteTool.allCases {
      let panel = ToolOptionsController(tool: tool, canvas: canvas)
      _ = panel.view
      expect(
        panel.preferredContentSize.height >= 85 && panel.preferredContentSize.height <= 450,
        "\(tool.rawValue) options have a compact usable layout")
    }
    let count = canvas.notebook.objects.count
    let start = CGPoint(x: 150, y: 205)
    send(.otherMouseDown, start)
    expect(canvas.buttons.scrolling, "lower button starts vertical scrolling")
    send(.leftMouseDown, start)
    send(.otherMouseDragged, CGPoint(x: 183, y: 165))
    send(.leftMouseDragged, CGPoint(x: 142, y: 146))
    send(.otherMouseUp, CGPoint(x: 142, y: 146))
    send(.leftMouseUp, CGPoint(x: 142, y: 146))
    pump(0.22)
    expect(
      owner.scrollView.contentView.bounds.origin.y > 2
        && owner.scrollView.contentView.bounds.origin.x == 0
        && canvas.notebook.objects.count == count,
      "holding lower button scrolls slowly and suppresses ink")
    owner.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    owner.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    send(.rightMouseDown, start)
    send(.rightMouseUp, start)
    expect(canvas.effectiveTool == .eraser, "upper button rearms after app focus changes")
    stroke([(215, 149)])
    expect(canvas.effectiveTool == .brush, "an empty erase pass also returns to Brush")
    owner.zoomIn(nil)
    let clip = owner.scrollView.contentView
    clip.scroll(to: CGPoint(x: 76, y: canvas.frame.height - clip.bounds.height - 8))
    owner.scrollView.reflectScrolledClipView(clip)
    pump(0.06)
    clip.scroll(to: CGPoint(x: 76, y: canvas.scale * (paperSize.height + 55)))
    owner.scrollView.reflectScrolledClipView(clip)
    pump(0.08)
    expect(
      canvas.pageCount > 2 && canvas.notebook.usedPages == 1,
      "scroll extends the grid without adding unused PDF pages")
    stroke([(82, paperSize.height + 110), (175, paperSize.height + 111)])
    expect(canvas.notebook.usedPages == 2, "ink on page two extends PDF export through page two")
    owner.clearPage(nil)
    expect(
      canvas.notebook.usedPages == 1 && canvas.notebook.objects.count == 5,
      "clear current page leaves previous page intact")
    owner.undoEdit(nil)
    canvas.setPaper(PaperDesign(ruling: .ruled, tint: .ivory), on: 1)
    expect(
      canvas.notebook.paper(on: 1).tint == .ivory && canvas.notebook.paper(on: 0).ruling == .grid,
      "per-page paper color and ruling are independent")
    owner.undoEdit(nil)
    expect(canvas.notebook.paper(on: 1) == PaperDesign(), "paper change is undoable")
    owner.redoEdit(nil)
    var samples = Notebook()
    for (i, design) in [
      PaperDesign(), PaperDesign(ruling: .ruled, tint: .ivory),
      PaperDesign(ruling: .dotted, tint: .sage), PaperDesign(ruling: .plain, tint: .blush),
    ].enumerated() {
      if samples.pagePaper == nil { samples.pagePaper = [:] }
      samples.pagePaper?[i] = design
    }
    try PaperRenderer().export(samples).write(to: qa.appendingPathComponent("papers.pdf"))
    let pdfBytes = try canvas.renderer.export(canvas.notebook)
    try pdfBytes.write(to: qa.appendingPathComponent("notebook.pdf"))
    let pdf = PDFDocument(data: pdfBytes)!
    expect(
      pdf.pageCount == 2
        && abs(pdf.page(at: 0)!.bounds(for: .mediaBox).width - paperSize.width) < 0.02,
      "export uses exact physical A4 pages")
    expect(
      pdf.page(at: 0)?.string?.contains("v = 6 m/s") == true, "typed text remains readable in PDF")
    owner.previewPDF(nil)
    pump(0.55)
    expect(win.attachedSheet?.title == "PDF Preview", "preview opens a native PDF sheet")
    if let sheet = win.attachedSheet { win.endSheet(sheet, returnCode: .cancel) }
    pump(0.1)
    let origin = clip.bounds.origin * (1 / canvas.scale)
    let zoom = canvas.frame.width / clip.bounds.width
    owner.checkpoint()
    let resumed = NotebookWindow(storage: storage, preferences: preferences, clipboard: pb)
    resumed.window?.setFrame(win.frame, display: true)
    resumed.restoreLastNotebook()
    resumed.showWindow(nil)
    pump(0.1)
    let resumeOrigin = resumed.scrollView.contentView.bounds.origin * (1 / resumed.canvas.scale)
    print(
      "Restored", resumeOrigin, "expected", origin, "objects", resumed.canvas.notebook.objects.count
    )
    expect(
      resumed.notebookURL?.standardizedFileURL == file.standardizedFileURL
        && resumed.canvas.notebook.objects.count == 6 && resumeOrigin.distance(to: origin) < 2,
      "last notebook and exact scroll position restore")
    expect(
      abs(resumed.canvas.frame.width / resumed.scrollView.contentView.bounds.width - zoom) < 0.01,
      "zoom restores")
    resumed.fitWidth(nil)
    expect(
      abs(resumed.canvas.frame.width - resumed.scrollView.contentView.bounds.width) < 1,
      "one-step Fit Width after relaunch")
    resumed.window?.orderOut(nil)

    let inputPDF = qa.appendingPathComponent("exercise.pdf")
    let original = try Data(contentsOf: inputPDF)
    owner.openFile(inputPDF)
    expect(
      canvas.notebook.sourcePages == 2 && owner.notebookURL?.pathExtension == "gridnote",
      "opening a PDF creates a separate editable notebook")
    stroke([(73, 147), (123, 147)])
    let annotated = try canvas.renderer.export(canvas.notebook)
    try annotated.write(to: qa.appendingPathComponent("annotated.pdf"))
    let actual = PDFDocument(data: annotated)!
    let originalAfter = try Data(contentsOf: inputPDF)
    expect(
      originalAfter == original && actual.pageCount == 2
        && actual.page(at: 0)?.string?.contains("Dynamics worksheet") == true,
      "annotated copy preserves source PDF and content")
    expect(
      actual.page(at: 1)?.string?.contains("Rotated and cropped") == true,
      "rotated cropped source page survives export")

    let broken = directory.appendingPathComponent("missing-folder/Recovered.gridnote")
    var recovery = Notebook()
    recovery.objects = [firstInk]
    recovery.revision = 11
    do {
      try storage.saveNow(recovery, to: broken)
      expect(false, "simulated file save failure")
    } catch {
      expect(
        error.localizedDescription.contains("recovery copy"),
        "failed primary save reports recovery availability")
    }
    let reopened = try NotebookStorage(directory: directory).open(broken, recovering: true)
    expect(
      reopened.recovered && reopened.notebook.revision == 11
        && reopened.notebook.objects == [firstInk],
      "fresh storage instance recovers the latest edits from damaged or missing primary")
    canvas.load(Notebook())
    owner.fitWidth(nil)
    canvas.chooseTool(.marker)
    stroke([(80, 62), (102, 62), (144, 62)])
    let marker = canvas.notebook.objects.last!
    expect(
      marker.instrument == "marker" && marker.opacity == preferences.markerOpacity,
      "highlighter preserves its opacity")
    expect(
      marker.transformed(from: .zero, offset: CGPoint(x: 2, y: 2)).instrument == "marker",
      "moving marker retains appearance")
    canvas.chooseTool(.shapes)
    for shape in ShapeKind.allCases {
      preferences.shape = shape
      stroke([(68, 92), (112, 118)])
      expect(canvas.notebook.objects.last?.instrument == "shape", "draw " + shape.rawValue)
    }
    canvas.chooseTool(.table)
    stroke([(80, 161), (325, 242)])
    expect(canvas.selectedObject?.table?.cells.count == 9, "visual table creation")
    canvas.configureTable(rows: 2, columns: 4, header: false, size: CGSize(width: 275, height: 75))
    let table = canvas.selectedObject!
    expect(
      table.frame.width == 275 && table.table?.header == false && table.table?.columns == 4,
      "numeric table size and header")
    let cell = CGPoint(x: 99, y: 173)
    send(.leftMouseDown, cell, clicks: 2)
    send(.leftMouseUp, cell, clicks: 2)
    canvas.editor?.insertText("Voltage", replacementRange: NSRange(location: 0, length: 0))
    expect(
      canvas.saveSnapshot.objects.last?.table?.cells.first == "Voltage",
      "uncommitted table cell checkpoints")
    var pos = ViewPosition()
    canvas.rememberInteraction(in: &pos)
    let snapshot = canvas.saveSnapshot
    canvas.finishText()
    canvas.load(snapshot)
    canvas.restoreInteraction(pos)
    expect(canvas.editor?.string == "Voltage", "cell editor and caret restore")
    canvas.finishText()
    pb.clearContents()
    pb.setString("int area(int x) { return x*x; }", forType: .string)
    canvas.paste(nil)
    expect(
      canvas.selectedObject?.codeStyle == true,
      "pasting a C fragment creates a syntax-colored code block")
    if let toggle = canvas.subviews.compactMap({ $0 as? NSButton }).first(where: {
      $0.title == "</>"
    }) {
      toggle.performClick(nil)
    }
    expect(canvas.selectedObject?.codeStyle == false, "selected code corner toggles colors")
    let text1 = NoteObject(
      frame: CGRect(x: 10, y: 50, width: 100, height: 30),
      content: .text("page one", InkColor.colors[0].1, 12))
    let text2 = text1.transformed(from: .zero, offset: CGPoint(x: 0, y: paperSize.height))
    var later = text2
    later.id = UUID()
    canvas.notebook.objects += [text1, later]
    canvas.clearAllWriting(typedOnly: true, page: 0)
    expect(
      !canvas.notebook.objects.contains(text1) && canvas.notebook.objects.contains(later),
      "page text removal is limited to the requested page")
    canvas.history.undo()
    canvas.clearAllWriting(typedOnly: true)
    expect(
      !canvas.notebook.objects.contains(text1) && !canvas.notebook.objects.contains(later)
        && canvas.notebook.objects.contains(where: { $0.codeStyle != nil })
        && canvas.notebook.objects.contains(where: { $0.table?.cells.first == "Voltage" })
        && canvas.notebook.objects.contains(where: { $0.instrument == "marker" }),
      "text-only removal preserves filled tables, code and marker")
    canvas.history.undo()
    expect(
      canvas.notebook.objects.contains(where: { $0.table?.cells.first == "Voltage" }),
      "undo preserves table contents")
    let snap = alignment(
      for: CGRect(x: 102, y: 200, width: 50, height: 30),
      near: [CGRect(x: 100, y: 100, width: 50, height: 20)], tolerance: 4)
    expect(snap.0.x == -2 && snap.1.count == 1, "alignment snaps an edge within screen tolerance")
    let solve = StudySolver()
    expect(
      solve.result("2x + 3 = 11", code: false)?["answer"] as? String == "x = 4",
      "offline linear solution from shared parser")
    expect(
      solve.result("x^2 - 5x + 6 = 0", code: false)?["answer"] as? String == "x = 2 or 3",
      "quadratic roots")
    expect(
      solve.result("return velocity * time", code: true)?["kind"] as? String == "Code",
      "unfinished code recognized without a main")
    var pageBook = Notebook()
    pageBook.sourcePages = 3
    pageBook.objects = [
      table.transformed(from: .zero, offset: CGPoint(x: 0, y: 2 * paperSize.height))
    ]
    canvas.load(pageBook)
    canvas.deletePage(1)
    expect(
      canvas.notebook.sourcePageMap == [0, 2] && canvas.notebook.usedPages == 2,
      "page deletion shifts objects and PDF backgrounds")
    canvas.history.undo()
    expect(canvas.notebook.usedPages == 3, "undo restores deleted page")
    canvas.load(Notebook())
    canvas.chooseTool(.brush)
    stroke([(50, 85), (250, 85)])
    let whole = canvas.notebook.objects
    preferences.eraseMode = .regular
    send(.rightMouseDown, CGPoint(x: 150, y: 85))
    send(.rightMouseUp, CGPoint(x: 150, y: 85))
    stroke([(150, 65), (150, 105)])
    expect(
      canvas.effectiveTool == .brush && canvas.notebook.objects.count == 2,
      "regular barrel eraser cuts fast sweeps into two editable fragments")
    expect(
      canvas.notebook.objects.allSatisfy { !$0.contains(CGPoint(x: 150, y: 85), tolerance: 1) },
      "the gap contains no ink")
    owner.undoEdit(nil)
    expect(canvas.notebook.objects == whole, "one undo restores exact original ink")
    preferences.nib = "Fineliner"
    expect(
      preferences.response(to: 0.1) == preferences.response(to: 1), "fineliner has constant width")
    preferences.scrollSpeed = 0.62
    preferences.usePressure = false
    preferences.width = 4
    preferences.restore(.brush)
    expect(
      preferences.width == 2 && preferences.nib == "Brush" && preferences.usePressure
        && preferences.scrollSpeed == 0.62 && preferences.eraseMode == .regular,
      "tool restore is scoped")
    preferences.restore()
    expect(
      preferences.eraseMode == .stroke && preferences.scrollSpeed == 0.30
        && canvas.notebook.objects == whole, "restore all settings preserves notebook")
    var pdfBook = Notebook(
      sourcePDF: try Data(contentsOf: qa.appendingPathComponent("exercise.pdf")), sourcePages: 2)
    pdfBook.objects = [text1]
    canvas.load(pdfBook)
    owner.togglePages(nil)
    owner.organize("insert", page: 0)
    expect(
      canvas.notebook.usedPages == 3 && canvas.notebook.sourceIndex(on: 1) == nil
        && canvas.notebook.sourceIndex(on: 2) == 1, "insert blank page between PDF pages")
    owner.organize("down", page: 0)
    expect(
      canvas.notebook.sourceIndex(on: 1) == 0
        && canvas.notebook.objects[0].frame.minY > paperSize.height,
      "moving page also moves annotations")
    let arrangedPDF = PDFDocument(data: try canvas.renderer.export(canvas.notebook))
    expect(arrangedPDF?.pageCount == 3, "reordered A4 PDF retains inserted page")
    owner.organize("delete", page: 1)
    canvas.history.undo()
    expect(
      canvas.notebook.sourceIndex(on: 1) == 0 && canvas.notebook.objects.count == 1,
      "undo restores removed page and its writing")
    owner.togglePages(nil)
    var inserted = ""
    let kit = SubjectToolsController(major: "Computer Science") { inserted = $0 }
    let web = kit.view as! WKWebView
    let webWindow = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 440, height: 380), styleMask: [.titled],
      backing: .buffered, defer: false)
    webWindow.contentView = web
    webWindow.orderBack(nil)
    for _ in 0..<100 where inserted.isEmpty {
      pump(0.06)
      web.evaluateJavaScript("document.getElementById('insert')?.click()")
    }
    expect(
      inserted.contains("11111111") && inserted.contains("FF"),
      "native study panel evaluates number bases and inserts its result")
    webWindow.orderOut(nil)
    let buttonState = TabletButtons()
    var mapped = buttonState
    expect(mapped.update(raw: [.penUpperSide], upper: nil, lower: nil), "raw upper switch edge")
    _ = mapped.update(raw: [.penLowerSide], upper: nil, lower: nil)
    expect(mapped.scrolling, "raw lower switch pans")
    var translated = TabletButtons()
    expect(
      translated.update(raw: [.penLowerSide], upper: true) && !translated.scrolling,
      "upper right-click wins over a remapped raw lower-side bit")
    _ = translated.update(raw: [.penLowerSide], upper: false)
    _ = translated.update(raw: [.penLowerSide])
    expect(
      !translated.scrolling, "duplicate raw samples after the upper release do not start scrolling")
    _ = translated.update(raw: [])
    _ = translated.update(raw: [.penLowerSide])
    expect(translated.scrolling, "independent lower-button scrolling returns after release")
    canvas.resetInputForFocus()
    expect(
      !canvas.buttons.scrolling && !canvas.buttons.eraserArmed,
      "focus reset clears stale button state")
    if let demo = ProcessInfo.processInfo.environment["GRIDNOTE_DEMO"] {
      let sample = directory.appendingPathComponent("Series circuit.gridnote")
      try FileManager.default.copyItem(at: URL(fileURLWithPath: demo), to: sample)
      owner.openFile(sample)
      win.setFrame(CGRect(x: 60, y: 40, width: 1060, height: 800), display: true)
      owner.fitWidth(nil)
      pump(0.2)
      try capture("demo-mac.png")
      try canvas.renderer.export(canvas.notebook).write(to: qa.appendingPathComponent("demo.pdf"))
      if ProcessInfo.processInfo.environment["GRIDNOTE_TEST_FULLSCREEN"] == "1" {
        win.toggleFullScreen(nil)
        pump(1.5)
        let full = win.styleMask.contains(.fullScreen)
        canvas.chooseTool(.brush)
        stroke([(106, 245), (127, 251)])
        send(.rightMouseDown, CGPoint(x: 110, y: 246))
        send(.rightMouseUp, CGPoint(x: 110, y: 246))
        stroke([(109, 245), (121, 249)])
        canvas.chooseTool(.selector)
        send(.otherMouseDown, CGPoint(x: 80, y: 200))
        send(.otherMouseUp, CGPoint(x: 80, y: 185))
        expect(
          full && win.styleMask.contains(.fullScreen),
          "native fullscreen stays active through writing, erasing, selecting and scrolling")
        win.toggleFullScreen(nil)
        pump(1.0)
      }
    }
    print("Finished \(checks) checks.")
    win.orderOut(nil)
  }
}
