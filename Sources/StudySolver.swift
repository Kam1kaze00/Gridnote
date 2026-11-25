import AppKit
import JavaScriptCore
import Vision

struct StudyProblem {
  var text: String
  var frame: CGRect
  var code: Bool
  var review = false
  var scan: ScanPageImage?
  var origin: String?
  var readings: [String] = []
}
final class StudySolver {
  private let js = JSContext()!
  init() {
    let url =
      Bundle.main.url(forResource: "solver", withExtension: "js")
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("web/solver.js")
    if let source = try? String(contentsOf: url, encoding: .utf8) { js.evaluateScript(source) }
  }
  func result(_ text: String, code: Bool) -> [String: Any]? {
    js.objectForKeyedSubscript("GridnoteSolve")?.invokeMethod(
      "solve", withArguments: [text, code])?.toDictionary() as? [String: Any]
  }
  func candidates(
    _ notebook: Notebook, page: Int, done: @escaping ([StudyProblem], String?) -> Void
  ) {
    let top = CGFloat(page) * paperSize.height
    let area = CGRect(x: 0, y: top, width: paperSize.width, height: paperSize.height)
    let objects = notebook.objects.filter { $0.frame.intersects(area) }
    var found: [StudyProblem] = []
    func add(_ value: String, _ f: CGRect, _ code: Bool) {
      if area.intersects(f), result(value, code: code) != nil {
        found.append(.init(text: value, frame: f.intersection(area), code: code))
      }
    }
    for o in objects {
      guard case .text(let text, _, let size) = o.content else { continue }
      if let table = o.table {
        for (i, cell) in table.cells.enumerated() {
          add(cell, table.cell(i, in: o.layoutFrame ?? o.frame), false)
        }
      } else if o.codeStyle != nil {
        add(text, o.frame, true)
      } else {
        let lines = text.components(separatedBy: "\n")
        var y = (o.layoutFrame ?? o.frame).minY
        for line in lines {
          let height = max(
            size * 1.2,
            NSAttributedString(string: line, attributes: o.textFormat.attributes()).boundingRect(
              with: CGSize(width: o.frame.width, height: 100000),
              options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
          add(
            line,
            CGRect(x: o.frame.minX, y: y, width: o.frame.width, height: height).intersection(
              o.frame), false)
          y += height
        }
      }
    }
    guard
      notebook.sourceIndex(on: page) != nil
        || objects.contains(where: {
          if case .text = $0.content { return false }
          return true
        })
    else {
      done(found, nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let visual = objects.filter {
        if case .text = $0.content { return false }
        return $0.instrument != "marker"
      }
      let rect =
        notebook.sourceIndex(on: page) != nil
        ? area
        : visual.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -8, dy: -8).intersection(
          area)
      guard !rect.isNull, rect.width > 0, rect.height > 0 else {
        DispatchQueue.main.async { done(found, nil) }
        return
      }
      let scale = min(4.2, sqrt(5_000_000 / (rect.width * rect.height)))
      guard
        let ctx = CGContext(
          data: nil, width: Int(ceil(rect.width * scale)),
          height: Int(ceil(rect.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else {
        DispatchQueue.main.async { done(found, "Couldn't prepare the page for scanning.") }
        return
      }
      ctx.scaleBy(x: scale, y: -scale)
      ctx.translateBy(x: -rect.minX, y: -rect.maxY)
      let renderer = PaperRenderer(pdfData: notebook.sourcePDF)
      ctx.setFillColor(CGColor(gray: 1, alpha: 1))
      ctx.fill(rect)
      if notebook.sourceIndex(on: page) != nil {
        renderer.draw(
          page: page, design: notebook.paper(on: page), sourceIndex: notebook.sourceIndex(on: page),
          originalScale: notebook.originalPDFScale == true, context: ctx)
      }
      for o in visual {
        if case .text = o.content { continue }
        renderer.draw(o, context: ctx)
      }
      guard let image = ctx.makeImage() else {
        DispatchQueue.main.async { done(found, "Couldn’t read this page.") }
        return
      }
      let scan = ScanPageImage(pixels: image, frame: rect, scale: scale)
      let pdfLines = selectablePDFLines(notebook, page: page, area: area)
      let photos = visual.compactMap { o -> StudyProblem? in
        if case .image = o.content {
          return .init(
            text: "", frame: o.frame.intersection(area), code: false, review: true, scan: scan,
            origin: "Photo")
        }
        return nil
      }
      let handwriting = handwritingRegions(visual, on: area).map {
        StudyProblem(
          text: "", frame: $0, code: false, review: true, scan: scan, origin: "Handwriting")
      }
      let diagram =
        visual.isEmpty && notebook.sourceIndex(on: page) != nil
        ? [
          StudyProblem(
            text: "", frame: area, code: false, review: true, scan: scan, origin: "PDF page")
        ] : []
      func finish(_ lines: [StudyProblem], _ error: String?) {
        DispatchQueue.main.async {
          var items = found + pdfLines.filter { self.result($0.text, code: false) != nil }
          for var line in lines {
            if let corrected = self.js.objectForKeyedSubscript("GridnoteSolve")?.invokeMethod(
              "readInk", withArguments: [line.text, line.readings])?.toString(),
              corrected != line.text
            {
              line.text = corrected
              line.review = true
            }
            guard self.result(line.text, code: false) != nil else { continue }
            if items.contains(where: {
              $0.frame.intersects(line.frame)
                && $0.text.trimmingCharacters(in: .whitespaces)
                  == line.text.trimmingCharacters(in: .whitespaces)
            }) {
              continue
            }
            line.scan = scan
            items.append(line)
          }
          for var region in handwriting + photos + diagram {
            let inside = lines.filter {
              region.frame.insetBy(dx: -4, dy: -4).contains(
                CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            region.text = inside.map(\.text).joined(separator: "\n")
            if region.origin == "Photo", inside.count > 1 {
              let indices = items.indices.filter {
                region.frame.intersects(items[$0].frame)
                  && self.result(items[$0].text, code: false)?["kind"] as? String == "Question"
              }
              if indices.count == 1 {
                items[indices[0]] = region
                continue
              }
            }
            if items.contains(where: {
              let overlap = $0.frame.intersection(region.frame)
              return !overlap.isNull
                && overlap.width * overlap.height > region.frame.width * region.frame.height * 0.75
            }) {
              continue
            }
            if region.origin == "PDF page" && !items.isEmpty { continue }
            items.append(region)
          }
          done(items, error)
        }
      }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.minimumTextHeight = 0.003
      request.usesLanguageCorrection = false
      do {
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { obs -> StudyProblem? in
          guard let best = obs.topCandidates(1).first, !best.string.isEmpty else { return nil }
          let b = obs.boundingBox
          return .init(
            text: best.string,
            frame: CGRect(
              x: rect.minX + b.minX * rect.width, y: rect.minY + (1 - b.maxY) * rect.height,
              width: b.width * rect.width, height: b.height * rect.height), code: false,
            review: best.confidence < 0.82, readings: obs.topCandidates(4).dropFirst().map(\.string)
          )
        }
        finish(lines, nil)
      } catch {
        finish([], "Image text recognition was unavailable.")
      }
    }
  }
}

final class StudyPanel: NSViewController {
  private let solver: StudySolver
  private let problem: StudyProblem?
  private let message: String
  private let entry = NSTextView()
  private let resultView = NSTextView()
  private var ask: NSButton!
  private var cropImage: NSImage?
  private var request: URLSessionDataTask?
  private var accountCall: ChatGPTCall?
  private var operation: UUID?
  private var connected = false
  private let accountLabel = chromeLabel("", size: 11)
  private let accountMenu = NSPopUpButton(frame: .zero, pullsDown: true)
  var keepOpenDuringSignIn: ((Bool) -> Void)?
  var sendToAccount = ChatGPTCall.send
  init(solver: StudySolver, problem: StudyProblem?, message: String) {
    self.solver = solver
    self.problem = problem
    self.message = message
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }
  deinit { request?.cancel(); accountCall?.cancel() }
  func cancelAI() {
    operation = nil
    request?.cancel()
    accountCall?.cancel()
    accountCall = nil
    keepOpenDuringSignIn?(false)
    ask?.title = "Ask AI"
    ask?.isEnabled = true
    entry.isEditable = true
  }
  override func loadView() {
    view = Surface(chromeToolbar)
    let stack = chromeStack([], spacing: 8, horizontal: false)
    view.addSubview(stack)
    defer {
      let size = stack.fittingSize
      preferredContentSize = CGSize(width: ceil(size.width) + 28, height: ceil(size.height) + 24)
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
    ])
    stack.addArrangedSubview(chromeLabel("Solve", size: 15, weight: .semibold))
    guard let problem else {
      let label = NSTextField(wrappingLabelWithString: message)
      label.preferredMaxLayoutWidth = 272
      label.widthAnchor.constraint(equalToConstant: 272).isActive = true
      label.setContentCompressionResistancePriority(.required, for: .vertical)
      stack.addArrangedSubview(label)
      return
    }
    stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
    func area(_ text: NSTextView, _ height: CGFloat, _ editable: Bool) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false
      scroll.borderType = .bezelBorder
      scroll.documentView = text
      text.isEditable = editable
      text.isSelectable = true
      text.isRichText = false
      text.font = .systemFont(ofSize: 13)
      text.isVerticallyResizable = true
      text.textContainerInset = CGSize(width: 4, height: 4)
      text.autoresizingMask = [.width]
      text.textContainer?.widthTracksTextView = true
      scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
      return scroll
    }
    if let crop = problem.scan?.crop(problem.frame) {
      let preview = NSImageView()
      cropImage = NSImage(cgImage: crop, size: CGSize(width: crop.width, height: crop.height))
      preview.image = cropImage
      preview.imageScaling = .scaleProportionallyUpOrDown
      preview.setAccessibilityLabel(problem.origin ?? "Scanned exercise")
      preview.heightAnchor.constraint(equalToConstant: 72).isActive = true
      stack.addArrangedSubview(preview)
      preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    let input = area(entry, 65, true)
    stack.addArrangedSubview(input)
    input.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    entry.string = problem.text
    let solve = NSButton(title: "Solve", target: self, action: #selector(calculate))
    ask = NSButton(title: "Ask AI", target: self, action: #selector(askAI))
    ask.toolTip = "Send this exercise and its selected image using your ChatGPT plan"
    let copy = NSButton(title: "Copy", target: self, action: #selector(copyExercise(_:)))
    copy.toolTip = "Copy the exercise text and selected image"
    let actions = chromeStack([solve, ask, copy], spacing: 5)
    actions.distribution = .fillEqually
    stack.addArrangedSubview(actions)
    actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    accountMenu.controlSize = .small
    accountMenu.setAccessibilityLabel("ChatGPT account options")
    accountMenu.toolTip = "ChatGPT sign-in, usage and study server"
    accountMenu.addItem(withTitle: "Account")
    func item(_ title: String, _ action: Selector) {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self
      accountMenu.menu?.addItem(entry)
    }
    item("Continue with ChatGPT", #selector(connectAccount))
    item("Manage usage…", #selector(manageUsage))
    item("Disconnect ChatGPT", #selector(disconnectAccount))
    accountMenu.menu?.addItem(.separator())
    item("Ask using study server", #selector(askServer))
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let accountRow = chromeStack([accountLabel, spacer, accountMenu], spacing: 3)
    stack.addArrangedSubview(accountRow)
    accountRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    updateAccount(false)
    _ = sendToAccount(["action": "status"]) { [weak self] status in
      guard let self, self.operation == nil else { return }
      self.updateAccount(status.connected)
    }
    let output = area(resultView, 134, false)
    stack.addArrangedSubview(output)
    output.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    if problem.review {
      resultView.string =
        problem.text.isEmpty
        ? "Enter the exercise to solve locally, or use Ask AI to read the selected image."
        : "Check the recognized text against the image, then click Solve."
    } else {
      calculate()
    }
  }
  @objc private func calculate() {
    cancelAI()
    if let r = solver.result(entry.string, code: problem?.code ?? false),
      let answer = r["answer"] as? String
    {
      let steps = r["steps"] as? [String] ?? []
      resultView.string =
        (steps.enumerated().map { "\($0.offset+1). \($0.element)" } + ["\nAnswer   " + answer])
        .joined(separator: "\n")
    } else {
      resultView.string =
        "Click Ask AI for a worked explanation. You can edit the exercise above first."
    }
  }
  private func updateAccount(_ value: Bool) {
    connected = value
    accountLabel.stringValue = value ? "Using your ChatGPT plan" : "Ask AI uses your ChatGPT plan"
    accountMenu.item(withTitle: "Disconnect ChatGPT")?.isHidden = !value
    accountMenu.item(withTitle: "Continue with ChatGPT")?.isHidden = value
  }

  @objc private func copyExercise(_ sender: NSButton) {
    let item = NSPasteboardItem()
    if let cropImage, let data = cropImage.tiffRepresentation { item.setData(data, forType: .tiff) }
    if !entry.string.isEmpty { item.setString(entry.string, forType: .string) }
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.writeObjects([item]) {
      sender.title = "Copied"
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak sender] in sender?.title = "Copy" }
    }
  }

  @objc private func manageUsage() {
    NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!)
  }

  private func accountOperation(_ body: [String: String], id: UUID, then: @escaping (ChatGPTReply) -> Void) {
    accountCall = sendToAccount(body) { [weak self] reply in
      guard let self, self.operation == id else { return }
      self.accountCall = nil
      self.updateAccount(reply.connected)
      then(reply)
    }
  }

  private func finishAI(_ text: String) {
    cancelAI()
    resultView.string = text
    resultView.scrollToBeginningOfDocument(nil)
  }

  @objc private func askAI() {
    if operation != nil { finishAI("Request canceled."); return }
    startAccount(solveAfterConnecting: true)
  }
  @objc private func connectAccount() { startAccount(solveAfterConnecting: false) }

  private func startAccount(solveAfterConnecting: Bool) {
    cancelAI()
    var exercise = ["action": "ask", "text": entry.string]
    if let crop = cropImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: crop),
       let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) {
      exercise["image"] = "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
    if solveAfterConnecting && entry.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && exercise["image"] == nil {
      finishAI("Enter an exercise or select an image."); return
    }
    let id = UUID()
    operation = id
    ask.title = "Cancel"
    entry.isEditable = false
    let solve: () -> Void = { [weak self] in
      guard let self else { return }
      self.resultView.string = "Solving with your ChatGPT plan…"
      self.accountOperation(exercise, id: id) { [weak self] reply in
        self?.finishAI(reply.error ?? reply.answer ?? "ChatGPT returned an empty answer.")
      }
    }
    if connected && solveAfterConnecting { solve(); return }
    keepOpenDuringSignIn?(true)
    resultView.string = "Approve Gridnote in your browser. Your answer will appear here."
    accountOperation(["action": "connect"], id: id) { [weak self] reply in
      guard let self else { return }
      NSApp.activate(ignoringOtherApps: true)
      self.view.window?.makeKeyAndOrderFront(nil)
      if let error = reply.error { self.finishAI(error); return }
      if solveAfterConnecting { solve() } else { self.finishAI("Connected. Ask AI uses your ChatGPT plan for the selected exercise.") }
    }
  }

  @objc private func disconnectAccount() {
    cancelAI()
    let id = UUID(); operation = id
    ask.isEnabled = false
    accountOperation(["action": "disconnect"], id: id) { [weak self] reply in
      self?.finishAI(reply.error ?? "Disconnected from ChatGPT.")
    }
  }

  @objc private func askServer() {
    cancelAI()
    let id = UUID()
    operation = id
    let source = entry.string
    var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/explain")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 90
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("1", forHTTPHeaderField: "X-Gridnote-Request")
    let kind = solver.result(source, code: problem?.code ?? false)?["kind"] as? String ?? "Question"
    var body = ["text": source, "kind": kind]
    if let cropImage, let tiff = cropImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
    {
      body["image"] = "data:image/jpeg;base64," + data.base64EncodedString()
    }
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    ask.isEnabled = false
    resultView.string = "Getting an explanation…"
    request = URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
      DispatchQueue.main.async {
        guard let self, self.operation == id, (err as? URLError)?.code != .cancelled else { return }
        self.ask.isEnabled = true
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        self.finishAI(body?["answer"] ?? body?["error"] ?? "The study server is unavailable. Use Ask AI to connect with ChatGPT.")
      }
    }
    request?.resume()
  }
}
