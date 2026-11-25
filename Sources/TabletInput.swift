import AppKit

struct TabletButtons {
  var rawUpper = false
  var rawLower = false
  var clickUpper = false
  var clickLower = false
  var eraserArmed = false
  var eraserContact = false
  private var suppressRawSides = false
  var keyboardPan = false

  var upperDown: Bool { rawUpper || clickUpper }
  var scrolling: Bool { rawLower || clickLower || keyboardPan }

  mutating func update(raw: NSEvent.ButtonMask? = nil, upper: Bool? = nil, lower: Bool? = nil)
    -> Bool
  {
    let previousUpper = upperDown
    if let upper { clickUpper = upper }
    if let lower { clickLower = lower }
    // The Wacom driver may report a logically remapped right-click as the
    // lower-side bit on the same sample. A translated button edge identifies
    // the configured action. Suppress its raw duplicate through release.
    if upper != nil || lower != nil || clickUpper || clickLower {
      suppressRawSides = true
      rawUpper = false
      rawLower = false
    } else if let raw {
      if raw.intersection([.penUpperSide, .penLowerSide]).isEmpty { suppressRawSides = false }
      rawUpper = !suppressRawSides && raw.contains(.penUpperSide)
      rawLower = !suppressRawSides && raw.contains(.penLowerSide)
    }
    return upperDown && !previousUpper
  }
}

extension NSEvent {
  var isPointerEvent: Bool {
    switch type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
      .rightMouseDragged,
      .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved:
      return true
    default: return false
    }
  }

  var isTabletSample: Bool { type == .tabletPoint || (isPointerEvent && subtype == .tabletPoint) }
  var isTabletProximity: Bool {
    type == .tabletProximity || (isPointerEvent && subtype == .tabletProximity)
  }
}

extension NoteCanvas {
  private static let tracePen = ProcessInfo.processInfo.environment["GRIDNOTE_PEN_TRACE"] == "1"
  private func trace(_ event: NSEvent, raw: NSEvent.ButtonMask?) {
    guard Self.tracePen, penTraceCount < 180 else { return }
    let kind: String
    switch event.type {
    case .mouseMoved, .tabletPoint, .leftMouseDragged, .otherMouseDragged, .rightMouseDragged:
      kind = "sample"
    default: kind = String(event.type.rawValue)
    }
    let line =
      "event=\(kind) raw=\(raw.map {String($0.rawValue)} ?? "-") tip=\(tipIsDown) armed=\(buttons.eraserArmed) contact=\(buttons.eraserContact) scroll=\(buttons.scrolling)"
    if line != penTraceLast {
      penTraceLast = line
      penTraceCount += 1
      FileHandle.standardError.write(Data(("GridnotePen " + line + "\n").utf8))
    }
  }
  func route(_ event: NSEvent) -> NSEvent? {
    guard active, let window = self.window else { return event }
    if event.isTabletProximity, event.window == nil || event.window === window {
      penInProximity = event.isEnteringProximity
      if !penInProximity {
        let keepArmed = buttons.eraserArmed && !buttons.eraserContact
        resetInputForFocus()
        if keepArmed {
          buttons.eraserArmed = true
          refreshTool()
        }
      } else {
        if event.vendorID != 0 { preferences.detectDevice(vendor: Int(event.vendorID)) }
        tabletEraser = event.pointingDeviceType == .eraser
      }
      return event
    }
    let targetlessTablet = event.type == .tabletPoint && event.window == nil && window.isKeyWindow
    guard event.window === window || targetlessTablet else { return event }
    if event.type == .keyUp, event.keyCode == 49, spacePan {
      spacePan = false
      buttons.keyboardPan = false
      lastPanLocation = nil
      refreshTool()
      return nil
    }
    if event.type == .keyDown {
      let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
      if editor != nil,
        event.keyCode == 53 || (flags == .command && (event.keyCode == 36 || event.keyCode == 76))
      {
        finishText(cancel: event.keyCode == 53)
        return nil
      }
      guard flags.isEmpty, editor == nil, !(window.firstResponder is NSTextView) else {
        return event
      }
      if event.keyCode == 49 {
        spacePan = true
        return nil
      }
      switch event.keyCode {
      case 12: chooseTool(.brush)
      case 13: chooseTool(.selector)
      case 14: chooseTool(.eraser)
      case 15: chooseTool(.text)
      default: return event
      }
      return nil
    }
    guard event.isPointerEvent || event.type == .tabletPoint else { return event }
    let windowPoint =
      targetlessTablet
      ? window.convertPoint(fromScreen: NSEvent.mouseLocation) : event.locationInWindow
    let local = convert(windowPoint, from: nil)
    let onPaper =
      visibleRect.contains(local) && editor?.frame.contains(local) != true
      && (enclosingScrollView?.contentView.visibleRect.contains(
        enclosingScrollView?.contentView.convert(windowPoint, from: nil) ?? .zero)
        ?? false)
    guard onPaper || tipIsDown || buttons.scrolling || buttons.upperDown || ignoredTip else {
      return event
    }

    var raw: NSEvent.ButtonMask?
    let lastTabletTip = lastTabletInput?.tip == true
    if event.isTabletSample {
      raw = event.buttonMask
      lastTabletInput = (
        windowPoint, event.timestamp, event.pressure, raw?.contains(.penTip) == true
      )
    }
    var upper: Bool?
    var lower: Bool?
    switch event.type {
    case .rightMouseDown:
      upper = true
      lower = nil
    case .rightMouseUp:
      upper = false
      lower = nil
    case .otherMouseDown where event.buttonNumber == 2:
      upper = nil
      lower = true
    case .otherMouseUp where event.buttonNumber == 2:
      upper = nil
      lower = false
    default:
      upper = nil
      lower = nil
    }

    let device = preferences.device
    if !device.supportsUpper {
      upper = nil
      raw?.remove(.penUpperSide)
    }
    if device == .wacomSingle, raw?.contains(.penLowerSide) == true { raw?.insert(.penUpperSide) }
    if !device.supportsLower {
      lower = nil
      raw?.remove(.penLowerSide)
    }
    let wasScrolling = buttons.scrolling
    if spacePan && event.type == .leftMouseDown { buttons.keyboardPan = true }
    if buttons.keyboardPan && event.type == .leftMouseUp { buttons.keyboardPan = false }
    let upperPressed = buttons.update(raw: raw, upper: upper, lower: lower)
    defer { trace(event, raw: raw) }
    if upperPressed, onPaper, !buttons.scrolling {
      if tipIsDown { finishGesture() }
      buttons.eraserArmed = true
      if tipIsDown { beginArmedErase(at: local) }
      refreshTool()
    }
    if buttons.scrolling {
      if !wasScrolling {
        finishText()
        finishGesture()
        ignoredTip = tipIsDown || raw?.contains(.penTip) == true
        lastPanLocation = windowPoint
        refreshTool()
      } else {
        movePenScroll(to: windowPoint)
      }
      if event.type == .leftMouseDown { ignoredTip = true }
      if event.type == .leftMouseUp
        || (event.type == .tabletPoint && lastTabletTip && raw?.contains(.penTip) == false)
      {
        ignoredTip = false
        tipIsDown = false
        returnToBrushAfterLift()
      }
      return nil
    }
    if wasScrolling {
      movePenScroll(to: windowPoint)
      lastPanLocation = nil
      refreshTool()
    }
    if event.type == .leftMouseDown, let raw,
      !raw.intersection([.penUpperSide, .penLowerSide]).isEmpty,
      !raw.contains(.penTip) || event.pressure == 0
    {
      translatedSideClick = true
      return nil
    }
    if event.type == .leftMouseUp, translatedSideClick, !tipIsDown {
      translatedSideClick = false
      return nil
    }
    if event.type == .leftMouseUp, ignoredTip {
      tipIsDown = false
      ignoredTip = false
      returnToBrushAfterLift()
      return nil
    }
    if event.type == .leftMouseDown, ignoredTip {
      // A new down event also proves that a suppressed tip contact has ended.
      ignoredTip = false
    }
    if event.type == .tabletPoint {
      if lastTabletTip, raw?.contains(.penTip) == false, tipIsDown || ignoredTip {
        tipIsDown = false
        ignoredTip = false
        finishGesture()
        returnToBrushAfterLift()
      } else if raw?.contains(.penTip) == true, !lastTabletTip, !tipIsDown, !ignoredTip, onPaper {
        startContact(event, at: local)
      } else if tipIsDown, !ignoredTip, onPaper {
        updateGesture(with: event, location: local)
      }
      return nil
    }
    if event.type == .rightMouseDragged || upper != nil { return nil }
    if event.type == .otherMouseDragged && event.buttonNumber == 2 || lower != nil { return nil }
    return event
  }

  private func movePenScroll(to location: CGPoint) {
    defer { lastPanLocation = location }
    guard let previous = lastPanLocation else { return }
    let delta = max(-75, min(75, location.y - previous.y))
    if abs(delta) > 0.01 { lastPenPanMotion = ProcessInfo.processInfo.systemUptime }
    enqueuePenScroll(delta)
  }

  func consumeDriverScroll(_ event: NSEvent) -> Bool {
    guard preferences.device.hasRockers, event.phase.isEmpty, event.momentumPhase.isEmpty,
      !event.modifierFlags.contains(.control)
    else { return false }
    let recent = lastTabletInput.map { abs(event.timestamp - $0.timestamp) < 0.18 } ?? false
    guard buttons.scrolling || (penInProximity && recent) else { return false }
    if buttons.eraserArmed { return true }
    if buttons.scrolling && ProcessInfo.processInfo.systemUptime - lastPenPanMotion < 0.1 {
      return true
    }
    if tipIsDown {
      finishGesture()
      ignoredTip = true
    }
    let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
    enqueuePenScroll(max(-75, min(75, -event.scrollingDeltaY * unit)))
    return true
  }
  private func enqueuePenScroll(_ delta: CGFloat) {
    pendingPan += delta * preferences.scrollSpeed
    guard panTimer == nil, abs(pendingPan) >= 0.08 else { return }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      self?.advancePenScroll()
    }
    panTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func advancePenScroll() {
    if abs(pendingPan) < 0.15 {
      // Keep the sub-pixel remainder while the pen is held to allow deliberate tiny moves.
      if !buttons.scrolling { pendingPan = 0 }
      panTimer?.invalidate()
      panTimer = nil
      return
    }
    let step = pendingPan * 0.43
    pendingPan -= step
    scrollBy?(step)
  }

  func resetInputForFocus() {
    finishGesture()
    returnToBrushAfterLift()
    buttons = TabletButtons()
    spacePan = false
    translatedSideClick = false
    tipIsDown = false
    ignoredTip = false
    tabletEraser = false
    penInProximity = false
    pendingPan = 0
    lastPanLocation = nil
    lastTabletInput = nil
    panTimer?.invalidate()
    panTimer = nil
    refreshTool()
  }

  override func magnify(with event: NSEvent) {
    pinch?(event.magnification, event.locationInWindow)
  }
}
