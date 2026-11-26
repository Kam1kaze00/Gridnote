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
  static func visibleViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
    guard !root.isHidden else { return [] }
    return (root as? T).map { [$0] } ?? root.subviews.flatMap { visibleViews(type, in: $0) }
  }
  static func checkToolControls(_ canvas: NoteCanvas) {
    let p = canvas.preferences
    for tool in NoteTool.allCases where tool != .brush {
      let panel = ToolOptionsController(tool: tool, canvas: canvas)
      let view = panel.view
      func control<T: NSControl>(_ type: T.Type, _ label: String) -> T {
        visibleViews(type, in: view).first { $0.accessibilityLabel() == label }!
      }
      func select(_ label: String, _ index: Int) {
        let segmented = control(NSSegmentedControl.self, label)
        segmented.selectedSegment = index
        segmented.sendAction(segmented.action, to: segmented.target)
      }
      func adjust(_ label: String, _ value: Double) {
        let slider = control(NSSlider.self, label)
        slider.doubleValue = value
        slider.sendAction(slider.action, to: slider.target)
      }
      func click(_ title: String) {
        visibleViews(NSButton.self, in: view).first { $0.title == title }!.performClick(nil)
      }
      switch tool {
      case .selector:
        select("Selection shape", 2)
        click("Alignment guides"); click("Ink"); click("Text")
        expect(
          p.selectionMode == .lasso && !p.guides && p.selectionMask == 4,
          "selector options update shape, guides and filters")
      case .eraser:
        for (index, mode) in EraseMode.allCases.enumerated() {
          select("Eraser mode", index)
          expect(
            p.eraseMode == mode
              && control(NSSlider.self, "Contact diameter").isEnabled
                == [.regular, .stroke].contains(mode),
            "eraser contact controls match " + mode.rawValue)
        }
        select("Eraser mode", 0)
        adjust("Contact diameter", 25)
        expect(p.eraserDiameter == 25, "contact diameter changes in Regular eraser")
      case .text:
        click("Insert code block"); select("Alignment", 2); adjust("Type size", 19)
        expect(
          p.code && p.textAlignment == .right && p.textSize == 19,
          "text options update code, alignment and size")
      case .marker:
        adjust("Width", 13); adjust("Opacity", 0.5)
        expect(
          p.markerWidth == 13 && p.markerOpacity == 0.5,
          "highlighter controls update width and opacity")
      case .shapes:
        select("Shape", 3); click("Constrain angles and proportions"); adjust("Line width", 4)
        expect(
          p.shape == .ellipse && p.constrain && p.shapeWidth == 4,
          "shape options update geometry, constraints and width")
      case .table:
        for (label, n) in [("Rows", 2), ("Columns", 4), ("Width (pt)", 230), ("Height (pt)", 90)] {
          let field = control(NSTextField.self, label)
          field.integerValue = n
          field.sendAction(field.action, to: field.target)
        }
        click("Header row")
        expect(
          p.grid.rows == 2 && p.grid.columns == 4 && !p.grid.header
            && p.tableSize == CGSize(width: 230, height: 90),
          "table controls update dimensions and header")
      case .brush: break
      }
      click("Restore tool defaults")
    }
  }
  static func checkWriter(_ owner: NotebookWindow) {
    let canvas = owner.canvas, preferences = canvas.preferences
    preferences.recognizeTabletPoint()
    let toolbar = visibleViews(ChromeButton.self, in: owner.window!.contentView!)
    let writer = toolbar.first { $0.shortcut == "Q" }!
    let toolButtons = toolbar.filter { $0.style == .choice }
    for tool in NoteTool.allCases {
      canvas.chooseTool(tool)
      let pressed = toolButtons.filter { $0.selected && $0.state == .on }
      expect(pressed.count == 1 && pressed[0].accessibilityLabel() == tool.title,
        "the toolbar marks only " + tool.title + " as active")
    }
    canvas.chooseTool(.brush)
    expect(writer.caption == "Writer", "Q toolbar button is named Writer")
    writer.performClick(nil)
    let popover = owner.settingsPopover!
    let panel = popover.contentViewController!.view
    let tips = visibleViews(ChromeButton.self, in: panel).filter { WritingTip(rawValue: $0.caption) != nil }
    let sliders = visibleViews(NSSlider.self, in: panel)
    let width = sliders.first { $0.accessibilityLabel() == "Width" }!
    let response = sliders.first { $0.accessibilityLabel() == "Pressure response" }!
    let toggle = visibleViews(NSButton.self, in: panel).first { $0.title == "Use pen pressure" }!
    expect(
      Set(tips.map(\.caption)) == Set(["Pen", "Brush", "Fineliner", "Gel", "Fountain", "Pencil"]),
      "Writer offers its six tips in one panel")
    func pick(_ tip: WritingTip) {
      let picked = tips.first { $0.caption == tip.rawValue }!
      picked.performClick(nil)
      let selectionMatches = tips.allSatisfy { button in
        let bounds = button.bounds
        let bitmap = button.bitmapImageRepForCachingDisplay(in: bounds)!
        button.cacheDisplay(in: bounds, to: bitmap)
        let color = bitmap.colorAt(x: bitmap.pixelsWide/12, y: bitmap.pixelsHigh/2)!.usingColorSpace(.sRGB)!
        let accented = color.greenComponent - color.redComponent > 0.25
        return accented == (button === picked) && (button.state == .on) == accented
      }
      expect(selectionMatches, "only " + tip.rawValue + " has the selected fill and pressed state")
      expect(
        preferences.nib == tip && writer.caption == "Writer" && writer.accessibilityLabel() == "Writer" && writer.toolTip == "Writer (Q)",
        "switch to " + tip.rawValue + " keeps the Writer name")
    }
    func set(_ slider: NSSlider, _ value: Double) {
      slider.doubleValue = value
      slider.sendAction(slider.action, to: slider.target)
    }
    func draw(_ pressures: [Double]) -> [CGFloat] {
      let start = ProcessInfo.processInfo.systemUptime
      for (i, pressure) in pressures.enumerated() {
        let type: CGEventType = i == 0 ? .leftMouseDown : .leftMouseDragged
        let cg = CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        cg.setIntegerValueField(.mouseEventSubtype, value: 1)
        cg.setDoubleValueField(.mouseEventPressure, value: 1)
        cg.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        cg.timestamp = UInt64((start + Double(i) * 0.025) * 1e9)
        let event = NSEvent(cgEvent: cg)!, point = CGPoint(x: 40 + i * 2, y: 80)
        if i == 0 {
          canvas.startContact(event, at: point)
        } else {
          canvas.updateGesture(with: event, location: point)
        }
      }
      canvas.resetInputForFocus()
      guard case .ink(let pts, _) = canvas.notebook.objects.last?.content else { return [] }
      return pts.map(\.radius)
    }
    func finishControl() -> NSSegmentedControl? {
      visibleViews(NSSegmentedControl.self, in: panel).first { $0.accessibilityLabel() == "Brush finish" }
    }
    let renderer = PaperRenderer()
    for tip in WritingTip.allCases {
      let finishes: [BrushFinish] = tip == .brush ? [.inked,.dry] : [.inked]
      for finish in finishes {
        let style = WritingStyle(tip: tip, width: 2.5, usesPressure: true, exponent: 1, finish: finish)
        let points = [InkPoint(position: CGPoint(x: 1,y: 2), radius: 3), InkPoint(position: CGPoint(x: 40,y: 2), radius: 3)]
        let path = renderer.footprint(points, ballpointWidth: tip == .pen ? style.width : nil, nib: style.inkNib)
        let ctx = CGContext(data: nil, width: 200, height: 20, bitsPerComponent: 8, bytesPerRow: 200,
          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0,y: 0,width: 200,height: 20))
        ctx.scaleBy(x: 5,y: 5)
        path.paint(color: InkColor(r: 0,g: 0,b: 0), context: ctx)
        ctx.flush()
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let center = (20..<180).map { Int(data[200*10+$0]) }.sorted()
        expect(center[156]-center[3] > 10, tip.rawValue+" shows paper grain inside the stroke")
      }
    }
    var spans: [CGFloat] = []
    for tip in WritingTip.allCases {
      pick(tip)
      expect((finishControl() != nil) == (tip == .brush), "finish selector appears only for Brush")
      expect(
        abs(width.doubleValue - tip.defaultWidth) < 0.01,
        tip.rawValue + " has its own starting width")
      set(width, 3)
      let radii = draw([0.1, 0.3, 0.6, 0.9])
      expect(!radii.isEmpty, "tablet event commits a visible stroke")
      spans.append(radii.max()! - radii.min()!)
      let object = canvas.notebook.objects.last!
      expect(object.ballpointWidth == (tip == .pen ? 3 : nil), "only pressure ballpoint has layered ink")
      if [.gel,.fountain,.brush,.pencil].contains(tip) {
        expect(object.inkNib?.tip == tip.rawValue && object.inkNib?.width == 3 && object.inkNib?.finish == (tip == .brush ? .inked : nil), "the selected writing material survives pen lift")
        let scaled = object.transformed(from: .zero, scale: 2, offset: .zero)
        expect(scaled.inkNib?.width == 6 && cutInk(object) { $0.position.x > 43 }.first?.inkNib == object.inkNib,
               "resizing and clipping preserve the material of a Writer stroke")
      }
      if tip == .pen, case .ink(let points, _) = object.content {
        let renderer = PaperRenderer()
        func coverage(_ point: InkPoint) -> CGFloat {
          let path = renderer.footprint([point], ballpointWidth: 3)
          return path.core!.boundingBoxOfPath.width / path.body.boundingBoxOfPath.width
        }
        expect(coverage(points.last!) > coverage(points.first!) + 0.55,
               "firm ballpoint contact fills more of the ink track")
        let resized = object.transformed(from: .zero, scale: 2, offset: .zero)
        expect(resized.ballpointWidth == 6, "resizing preserves ballpoint shading")
        let pieces = cutInk(object) { $0.position.x > 43 }
        expect(!pieces.isEmpty && pieces.allSatisfy { $0.ballpointWidth == 3 },
               "trimmed ballpoint fragments retain ink density")
      }
    }
    expect(
      spans[0] > 0.2 && spans[1] > 3 * spans[0] && spans[2] < 0.0001,
      "embedded Wacom pressure produces a ballpoint, expressive brush and uniform fineliner")
    pick(.fineliner)
    expect(!response.isEnabled && !toggle.isEnabled, "Fineliner keeps a fixed tip")
    pick(.brush)
    set(width, 4)
    let brush = preferences.writingStyle
    expect(brush.sampledRadius(force: nil, previous: 3, distance: 6, elapsed: 0.01,
                               lift: true, stylus: true) < 1 &&
           brush.sampledRadius(force: nil, previous: 3, distance: 0, elapsed: 0.01,
                               lift: true, stylus: true) == 3, "a moving lift tapers and a brush dot survives")
    let firmLine = [InkPoint(position: .zero, radius: 3), InkPoint(position: CGPoint(x: 45, y: 0), radius: 3)]
    let tapered = brush.fittedInk(firmLine, smoothing: 0, lifted: true)
    expect(tapered.first!.position == .zero && tapered.last!.position == firmLine.last!.position &&
      tapered.first!.radius < 1 && tapered.last!.radius < 0.4 && tapered.map(\.radius).max() == 3,
      "a brush has a pointed entry and release even when tip-up repeats the last position")
    let upright = brush.sampledRadius(force: 0.6, previous: nil, distance: 3, elapsed: 0.01, lift: false, stylus: true)
    let tilted = brush.sampledRadius(force: 0.6, previous: nil, distance: 3, elapsed: 0.01, lift: false, stylus: true, crossTilt: 0.8)
    expect(tilted > 1.25 * upright, "tilting the brush across its motion broadens a loaded stroke")
    let line = WritingStyle(tip: .fineliner, width: 1, usesPressure: true, exponent: 1)
    let jitter = [CGPoint(x: 0,y: 0), CGPoint(x: 3,y: 0.14), CGPoint(x: 6,y: 0)].map { InkPoint(position: $0,radius: 0.5) }
    let ordinary = smoothedInk(jitter, amount: 0.8, times: [0,0.004,0.008])
    let ruled = line.fittedInk(jitter, smoothing: 0.8, times: [0,0.004,0.008])
    expect(ruled[ruled.count/2].position.y < ordinary[ordinary.count/2].position.y &&
      ruled.allSatisfy { $0.radius == 0.5 }, "fineliner damps sub-nib wobble while keeping its specified line width")
    set(response, 0.5)
    let soft = draw([0.3])[0]
    set(response, 2)
    expect(soft > draw([0.3])[0] * 2, "Soft and Firm change the actual stroke at the same force")
    toggle.performClick(nil)
    expect(
      Set(draw([0.1, 0.9])) == [2] && !response.isEnabled,
      "pressure off honors the exact chosen width")
    pick(.pen)
    expect(width.doubleValue == 3, "returning to Pen restores its width in the slider")
    let flow = visibleViews(NSSlider.self, in: panel).first { $0.accessibilityLabel() == "Ink flow" }!
    set(width, 1)
    set(flow, 0.25)
    let thin = draw([0.5, 0.5, 0.5])
    let light = canvas.notebook.objects.last!
    set(width, 4)
    set(flow, 1)
    let thick = draw([0.5, 0.5, 0.5])
    let dark = canvas.notebook.objects.last!
    expect(thin[0] == 0.5 && thick[0] == 2 && light.opacity == 0.25 && dark.opacity == nil,
           "Pen width and flow from the Writer popup reach the very next tablet stroke")
    func darkness(_ stroke: NoteObject) -> Int {
      let side = 96
      let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
      ctx.setFillColor(gray: 1, alpha: 1)
      ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
      ctx.scaleBy(x: 8, y: 8)
      ctx.translateBy(x: -36, y: -74)
      PaperRenderer().draw(stroke, context: ctx)
      ctx.flush()
      let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
      return (0..<side*side).reduce(0) { $0 + 255 - Int(pixels[$1]) }
    }
    var sameWidth = light
    sameWidth.opacity = nil
    expect(darkness(light) > 0 && darkness(sameWidth) > 2 * darkness(light),
           "lower ink flow visibly lightens the rendered ballpoint at the same width")
    expect(canvas.notebook.objects.suffix(2).first?.opacity == 0.25,
           "changing Pen controls leaves the previous stroke as drawn")
    pick(.brush)
    let finish = finishControl()!
    expect(finish.selectedSegment == 0, "Brush defaults to Inked")
    finish.selectedSegment = 1
    finish.sendAction(finish.action, to: finish.target)
    _ = draw([0.2, 0.6, 0.9, 0.5, 0.1])
    let dry = canvas.notebook.objects.last!
    let reopened = try! JSONDecoder().decode(NoteObject.self, from: JSONEncoder().encode(dry))
    expect(reopened.inkNib?.finish == .dry && reopened == dry, "Dry strokes keep their finish on disk")
    pick(.pen)
    pick(.brush)
    expect(preferences.brushFinish == .dry && finish.selectedSegment == 1, "Brush remembers the selected finish")
    expect(width.doubleValue == 4, "returning to Brush restores its own width")
    popover.close()
    preferences.restore()
    canvas.load(Notebook())
    canvas.chooseTool(.brush)
    owner.window?.makeFirstResponder(canvas)
  }
  static func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    let qa = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let directory = qa.appendingPathComponent("session-" + UUID().uuidString, isDirectory: true)
    let defaults = UserDefaults(suiteName: "gridnote.qa." + UUID().uuidString)!
    let preferences = PenPreferences(defaults: defaults)
    let brushSymbols = WritingTip.allCases.map { tip in
      preferences.nib = tip
      return preferences.toolAppearance(.brush).symbol
    }
    expect(Set(brushSymbols).count == WritingTip.allCases.count, "each writing tip has its own toolbar symbol")
    let eraseSymbols = EraseMode.allCases.map { mode in
      preferences.eraseMode = mode
      return preferences.toolAppearance(.eraser).symbol
    }
    expect(Set(eraseSymbols).count == 4, "each eraser mode has its own toolbar symbol")
    let oldPaper = Data(#"{"ruling":"Dotted","tint":"Sage","stationery":"Pixelated"}"#.utf8)
    let importedPaper = try JSONDecoder().decode(PaperDesign.self, from: oldPaper)
    let paperKeys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(importedPaper)) as! [String: String]
    expect(paperKeys == ["ruling": "Dotted", "tint": "Sage"], "older paper keeps its ruling and tint")
    let resized = resizeFeedback(
      CGRect(x: 10, y: 10, width: 100, height: 50),
      targets: [CGRect(x: 140, y: 100, width: 100, height: 49)], fixed: CGPoint(x: 10, y: 10),
      tolerance: 2)
    expect(
      resized.matches == ["W", "H"] && resized.guides.count >= 12,
      "resize guides compare both dimensions with other objects")
    let sampleImage = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    sampleImage.size = CGSize(width: 200, height: 100)
    let retina = try PaperRenderer.importImage(
      sampleImage.representation(using: .png, properties: [:])!)
    expect(
      abs(retina.size.width - 200) < 0.1 && abs(retina.size.height - 100) < 0.1,
      "Retina screenshot keeps its logical size")
    let storage = NotebookStorage(directory: directory)
    let pb = NSPasteboard.withUniqueName()
    let owner = NotebookWindow(storage: storage, preferences: preferences, clipboard: pb)
    let win = owner.window!
    let canvas = owner.canvas
    GridnoteDelegate.installMenus(owner)
    NSApp.finishLaunching()
    var launchAction = ""
    let launchController = LauncherController(preferences: preferences, last: directory.appendingPathComponent("Example.gridnote")) { action, _ in launchAction = action }
    launchController.showWindow(nil)
    let launchWeb = launchController.window!.contentView as! WKWebView
    var fits = false
    for _ in 0..<100 where !fits {
      pump(0.04)
      launchWeb.evaluateJavaScript("""
        (() => {
          const card = document.querySelector(".start-card")?.getBoundingClientRect();
          return !!card && card.x === 0 && card.y === 0 && Math.abs(card.width - innerWidth) < 1
            && Math.abs(card.height - innerHeight) <= 1
            && document.querySelector("#continue small")?.textContent === "Example";
        })()
        """) { result, _ in fits = result as? Bool == true }
    }
    expect(fits && launchAction.isEmpty, "compact launcher fits its content and waits for a choice")
    launchWeb.evaluateJavaScript("document.querySelector('#continue').click()")
    for _ in 0..<100 where launchAction.isEmpty { pump(0.06) }
    expect(launchAction == "continue", "standalone Mac launcher continues only on request")
    launchController.dismiss()
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
    checkWriter(owner)
    checkToolControls(canvas)
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
    let placedImage = canvas.notebook.objects[0]
    let naturalImage = try PaperRenderer.importImage(data)
    let placementScale = min(1, (150 * 72 / 25.4) / naturalImage.size.width,
      (100 * 72 / 25.4) / naturalImage.size.height,
      0.85 * canvas.visibleRect.width / naturalImage.size.width,
      0.6 * canvas.visibleRect.height / naturalImage.size.height)
    expect(abs(placedImage.frame.width - naturalImage.size.width * placementScale) < 0.1
      && abs(placedImage.frame.height - naturalImage.size.height * placementScale) < 0.1
      && placedImage.content == .image(naturalImage.data), "pasted image fits the page and retains its pixels")
    canvas.fitSelectedImage(nil)
    let enlarged = canvas.selectedObject!
    canvas.copy(nil)
    canvas.paste(nil)
    expect(canvas.selectedObject!.frame.width < enlarged.frame.width &&
      canvas.selectedObject!.id != enlarged.id, "a copied large photo also pastes at the notebook size limit")
    owner.undoEdit(nil)
    owner.undoEdit(nil)
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
    let pageContents = canvas.notebook.objects
    owner.clearPage(nil)
    expect(canvas.notebook.objects == pageContents.filter {
      if case .ink = $0.content { return $0.instrument != nil }
      return true
    } && canvas.notebook.objects.contains(where: { $0.id == imageID }),
      "page cleanup keeps typed notes and pasted images")
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
    owner.jumpToPage(1)
    owner.previewPDF(nil)
    pump(0.55)
    expect(win.attachedSheet?.title == "PDF Preview", "preview opens a native PDF sheet")
    if let sheet = win.attachedSheet {
      let pdfView = visibleViews(PDFView.self, in: sheet.contentView!).first
      expect(pdfView?.currentPage.flatMap { pdfView?.document?.index(for: $0) } == 1,
        "preview opens at the current writing page")
      win.endSheet(sheet, returnCode: .cancel)
    }
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
    var damaged = Notebook()
    var damagedInk = firstInk
    damagedInk.content = .ink([], InkColor.colors[0].1)
    damaged.objects = [damagedInk]
    let invalidFile = directory.appendingPathComponent("incomplete.gridnote")
    try JSONEncoder().encode(damaged).write(to: invalidFile)
    let rejected = (try? storage.open(invalidFile)) == nil
    expect(rejected, "incomplete ink is rejected before replacing the open notebook")
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
      if shape == .axes {
        let color = InkColor.colors[0].1
        let a = CGPoint(x: 10, y: 15), b = CGPoint(x: 130, y: 95)
        let graph = shapeInk(a, b, shape: .axes, constrained: false, width: 1, color: color)!
        let reverse = shapeInk(b, a, shape: .axes, constrained: false, width: 1, color: color)!
        expect(graph.content == reverse.content, "axes always point right and up")
        expect(graph.contains(CGPoint(x: 70, y: 55), tolerance: 1) &&
               graph.contains(CGPoint(x: 70 + paperGrid, y: 57), tolerance: 0.5) &&
               !graph.contains(CGPoint(x: 88, y: 73), tolerance: 1),
               "axes cross at center with ticks and empty quadrants")
      }
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
    send(.leftMouseDown, cell)
    send(.leftMouseUp, cell)
    expect(canvas.editor != nil, "one Selector tap edits a table cell")
    canvas.editor?.insertText("Voltage", replacementRange: NSRange(location: 0, length: 0))
    expect(
      canvas.saveSnapshot.objects.last?.table?.cells.first == "Voltage",
      "uncommitted table cell checkpoints")
    var pos = ViewPosition()
    canvas.rememberInteraction(in: &pos)
    let snapshot = canvas.saveSnapshot
    canvas.finishText()
    canvas.load(snapshot)
    var missingCell = pos
    missingCell.cell = nil
    canvas.restoreInteraction(missingCell)
    expect(canvas.editor == nil, "A stale cell selection cannot reopen the whole table as plain text")
    canvas.finishText()
    canvas.restoreInteraction(pos)
    expect(canvas.editor?.string == "Voltage", "cell editor and caret restore")
    expect(
      key("\t", 48) == nil && canvas.editor?.string == "",
      "Tab commits the cell and opens its neighbor")
    canvas.editor?.insertText("Current", replacementRange: NSRange(location: 0, length: 0))
    canvas.chooseTool(.text)
    canvas.changeFormat(table: false) {
      $0.traits = 7; $0.alignment = .right; $0.color = InkColor.colors[3].1
    }
    let styled = canvas.selectedObject!
    expect(
      styled.table?.formats?["0:1"]?.traits == 7 && styled.table?.formats?["0:0"] == nil,
      "cell emphasis and color are independent of neighboring cells")
    canvas.chooseTool(.table)
    canvas.changeFormat(table: true) { $0.size = 16 }
    expect(
      canvas.selectedObject?.textFormat.size == 16
        && canvas.selectedObject?.table?.formats?["0:1"]?.size == 16,
      "table-wide change preserves independent cell formatting")
    let formattedNotebook = try JSONDecoder().decode(
      Notebook.self, from: JSONEncoder().encode(canvas.saveSnapshot))
    expect(
      formattedNotebook.objects.last?.table?.formats?["0:1"]?.alignment == .right,
      "cell formatting survives notebook round-trip")
    let tablePanel = ToolOptionsController(tool: .table, canvas: canvas)
    let picker = visibleViews(TablePicker.self, in: tablePanel.view).first!
    _ = picker.accessibilityPerformPress()
    expect(
      canvas.selectedObject?.table?.cells.count == 1
        && canvas.notebook.objects.count == formattedNotebook.objects.count + 1,
      "grid picker inserts a new table even when another is selected")
    canvas.history.undo()
    expect(
      canvas.notebook.objects == formattedNotebook.objects,
      "undo grid insertion restores the formatted table")
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
    let writer = NoteObject.ink([.init(position: CGPoint(x: 100, y: 100), radius: 1)],
      color: InkColor.colors[0].1)!
    var nextPageWriter = writer.transformed(from: .zero, offset: CGPoint(x: 0, y: paperSize.height))
    nextPageWriter.id = UUID()
    let boundary = paperSize.height
    let crossing = NoteObject.ink([.init(position: CGPoint(x: 80, y: boundary - 12), radius: 1),
      .init(position: CGPoint(x: 80, y: boundary + 30), radius: 1)], color: InkColor.colors[0].1)!
    canvas.notebook.objects += [text1, later, writer, nextPageWriter, crossing]
    owner.jumpToPage(0)
    let originals = canvas.notebook.objects
    let clearButton = visibleViews(ChromeButton.self, in: screen).first { $0.caption == "Clear Writing" }
    expect(clearButton != nil, "current-page Clear Writing button is visible")
    clearButton?.performClick(nil)
    let clearedObjects = canvas.notebook.objects
    let kept = originals.filter { object in
      if case .ink = object.content { return object.instrument != nil || object.frame.minY >= boundary }
      return true
    }
    expect(kept.allSatisfy(clearedObjects.contains) && !clearedObjects.contains(writer),
      "Clear Writing preserves typed text, highlighter, objects and the next page")
    expect(clearedObjects.contains(where: { $0.id == crossing.id && $0.frame.minY >= boundary - 1 }),
      "a stroke crossing the break retains its next-page portion")
    clearButton?.performClick(nil)
    owner.undoEdit(nil)
    expect(canvas.notebook.objects == originals, "one Undo restores exact strokes after two clicks")
    owner.redoEdit(nil)
    expect(canvas.notebook.objects == clearedObjects, "Redo reapplies current-page handwriting removal")
    owner.undoEdit(nil)
    owner.clearAll(nil)
    expect(!canvas.notebook.objects.contains(nextPageWriter) && canvas.notebook.objects.contains(later),
      "all-page writing removal also keeps typed text")
    owner.undoEdit(nil)
    owner.clearPageText(nil)
    expect(!canvas.notebook.objects.contains(text1) && canvas.notebook.objects.contains(later)
      && canvas.notebook.objects.contains(writer), "separate current-page typed-text removal")
    owner.undoEdit(nil)
    canvas.clearWriting(.typedText)
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
    let solveButton = visibleViews(ChromeButton.self, in: screen).first { $0.caption == "Solve" }!
    var exerciseBook = Notebook()
    let equation = NoteObject(frame: CGRect(x: 45, y: 100, width: 160, height: 25),
      content: .text("5x + 4 = 3", InkColor.colors[0].1, 14))
    exerciseBook.objects = [equation]
    canvas.load(exerciseBook)
    owner.jumpToPage(0)
    solveButton.performClick(nil)
    pump(0.35)
    expect(owner.settingsPopover?.isShown == true && canvas.studyProblems.count == 1,
      "one exercise opens directly from Solve")
    owner.settingsPopover?.performClose(nil)
    pump(0.25)
    expect(canvas.studyProblems.isEmpty, "closing one answer returns to writing")
    var second = equation.transformed(from: .zero, offset: CGPoint(x: 0, y: 120))
    second.id = UUID()
    exerciseBook.objects.append(second)
    exerciseBook.revision += 1
    canvas.load(exerciseBook)
    solveButton.performClick(nil)
    pump(0.35)
    expect(canvas.studyProblems.count == 2 && owner.settingsPopover?.isShown != true,
      "two exercises offer a choice on the page")
    solveButton.performClick(nil)
    let solve = StudySolver()
    do {
      let panel = StudyPanel(solver: solve, problem: StudyProblem(text: "5x + 4 = 3", frame: .zero, code: false), message: "")
      var calls: [String] = []
      panel.sendToAccount = { body, done in
        let action = body["action"]!
        calls.append(action)
        DispatchQueue.main.async { done(ChatGPTReply(connected: action != "status", answer: action == "ask" ? "x = -0.2" : nil)) }
        return ChatGPTCall()
      }
      let view = panel.view
      view.setFrameSize(panel.preferredContentSize)
      view.layoutSubtreeIfNeeded()
      let buttons = visibleViews(NSButton.self, in: view)
      let actions = ["Solve","Ask AI","Copy"].map { name in buttons.first { $0.title == name }! }
      let rects = actions.map { $0.convert($0.bounds, to: view) }
      expect(rects.allSatisfy { abs($0.midY-rects[0].midY) <= 1 && abs($0.width-rects[0].width) <= 1 && view.bounds.contains($0) },
        "Solve, Ask AI and Copy fit in one evenly aligned row")
      actions[1].performClick(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
      expect(calls == ["status","connect","ask"] && visibleViews(NSTextView.self, in: view).contains { $0.string == "x = -0.2" },
        "one Ask AI click continues after sign-in and puts the answer in the original popup")
    }
    do {
      let message = "No supported problem found on this page. Type an equation, or add a code block in Text options."
      let short = StudyPanel(solver: solve, problem: nil, message: "Image text recognition was unavailable.")
      _ = short.view
      let panel = StudyPanel(solver: solve, problem: nil, message: message)
      let view = panel.view
      view.setFrameSize(panel.preferredContentSize)
      view.layoutSubtreeIfNeeded()
      let stack = view.subviews[0] as! NSStackView
      let title = stack.arrangedSubviews[0], body = stack.arrangedSubviews[1] as! NSTextField
      let t = title.convert(title.bounds, to: view), b = body.convert(body.bounds, to: view)
      expect(abs(t.minX - b.minX) < 1 && abs(b.minX - (view.bounds.maxX - b.maxX)) < 1 &&
        abs(b.minY - 12) < 1.1 && abs(view.bounds.maxY - t.maxY - 12) < 1.1 &&
        b.height >= body.intrinsicContentSize.height - 1 &&
        panel.preferredContentSize.height > short.preferredContentSize.height,
        "Solve fits its wrapped message with even padding")
    }
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
    owner.jumpToPage(1)
    owner.deletePage(nil)
    expect(
      canvas.notebook.sourcePageMap == [0, 2] && canvas.notebook.usedPages == 2,
      "page deletion shifts objects and PDF backgrounds")
    canvas.history.undo()
    expect(canvas.notebook.usedPages == 3, "undo restores deleted page")
    owner.jumpToPage(2)
    owner.deletePage(nil)
    expect(owner.page == 1 && canvas.notebook.usedPages == 2, "Delete This Page lands on the remaining last page")
    owner.jumpToPage(0)
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
    preferences.nib = .fineliner
    expect(
      preferences.writingStyle.radius(at: 0.1) == preferences.writingStyle.radius(at: 1),
      "fineliner has constant width")
    preferences.scrollSpeed = 0.62
    preferences.usePressure = false
    preferences.width = 4
    preferences.restore(.brush)
    expect(
      preferences.width == 2 && preferences.nib == .brush && preferences.usePressure
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
    let sidebar = visibleViews(PageSidebar.self, in: screen)[0]
    do {
      canvas.refreshTool()
      screen.layoutSubtreeIfNeeded()
      let actions = visibleViews(ChromeButton.self, in: sidebar).sorted { $0.tag < $1.tag }
      owner.jumpToPage(2)
      expect(sidebar.table.selectedRow == -1 && !actions[3].isEnabled && !actions[1].isEnabled,
        "An unused sheet never targets the previous page for deletion or movement")
      actions[0].performClick(nil)
      expect(canvas.notebook.usedPages == 3 && sidebar.table.selectedRow == 2 && owner.page == 2,
        "Add this page includes the visible blank sheet without moving earlier pages")
      canvas.history.undo()
      expect(canvas.notebook.usedPages == 2 && canvas.notebook.sourceIndex(on: 1) == 1,
        "Undo adding the visible sheet preserves the original two PDF pages")
      owner.jumpToPage(1)
      expect(sidebar.table.selectedRow == 1 && actions[3].isEnabled,
        "Returning to a used sheet enables actions for that page")
      owner.jumpToPage(0)
      let frames = actions.map { $0.convert($0.bounds, to: sidebar) }
      let list = sidebar.table.enclosingScrollView!
      let listFrame = list.convert(list.bounds, to: sidebar)
      let heading = visibleViews(NSTextField.self, in: sidebar).first { $0.stringValue == "Pages" }!
      let leading = heading.convert(heading.alignmentRect(forFrame: heading.bounds), to: sidebar).minX
      expect(frames.count == 4 && abs(frames[0].minX - leading) <= 1 &&
        abs(frames[0].minX - listFrame.minX) <= 1 && abs(frames[3].maxX - listFrame.maxX) <= 1 &&
        abs(sidebar.bounds.maxX - frames[3].maxX - leading) <= 1 &&
        frames.allSatisfy { abs($0.width - frames[0].width) <= 1 && abs($0.midY - frames[0].midY) <= 1 },
        "Sidebar heading, four page actions and thumbnails share their margins")
    }
    canvas.refreshTool()
    try capture("page-sidebar.png")
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
      canvas.refreshTool()
      win.setFrame(CGRect(x: 60, y: 40, width: 1060, height: 800), display: true)
      owner.fitWidth(nil)
      pump(0.2)
      try capture("demo-mac.png")
      let priorSize = win.frame.size
      for width: CGFloat in [760, 1024] {
        win.setContentSize(CGSize(width: width, height: 600))
        win.contentView?.layoutSubtreeIfNeeded()
        pump(0.05)
        let buttons = visibleViews(ChromeButton.self, in: screen)
        for group in Dictionary(grouping:buttons.filter { $0.superview is NSStackView }, by:{ObjectIdentifier($0.superview!) }).values {
          let row = group.sorted { $0.frame.minX < $1.frame.minX }
          if (row.first?.superview as? NSStackView)?.orientation == .horizontal {
            expect(zip(row,row.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX + 1 }, "Mac toolbar buttons have separate hit areas")
          }
        }
        expect(win.contentView!.bounds.width >= 750,  "active Mac editor lays out at " + String(Int(width)) + " points")
      }
      let pdf = try canvas.renderer.export(canvas.notebook)
      expect(PDFDocument(data: pdf)?.pageCount == canvas.notebook.usedPages, "sample exports all used pages")
      win.setFrame(CGRect(origin:win.frame.origin,size:priorSize), display:true)
      canvas.refreshTool()
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
