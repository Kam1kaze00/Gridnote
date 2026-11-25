import AppKit
import UniformTypeIdentifiers
import WebKit

final class LauncherController: NSWindowController, WKScriptMessageHandler, NSWindowDelegate {
  private static let cardWidth: CGFloat = 428
  private var cardHeight: CGFloat = 224
  private let start: (String, URL?) -> Void
  private var web: WKWebView!
  init(preferences: PenPreferences, last: URL?, start: @escaping (String, URL?) -> Void) {
    self.start = start
    let width = min(Self.cardWidth, NSScreen.main?.visibleFrame.width ?? Self.cardWidth)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: cardHeight),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Gridnote"
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: .darkAqua)
    window.center()
    super.init(window: window)
    window.delegate = self
    let config = WKWebViewConfiguration()
    let options: [String: Any] = [
      "device": preferences.deviceDescription,
      "lastName": last?.deletingPathExtension().lastPathComponent ?? "", "hasLast": last != nil]
    if let data = try? JSONSerialization.data(withJSONObject: options),
       let json = String(data: data, encoding: .utf8) {
      config.userContentController.addUserScript(WKUserScript(source: "window.launchOptions = " + json,
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    config.userContentController.add(self, name: "gridnoteLauncher")
    web = WKWebView(frame: .zero, configuration: config)
    web.underPageBackgroundColor = chromeBackground
    window.contentView = web
    let url = Bundle.main.url(forResource: "launcher", withExtension: "html")
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("web/launcher.html")
    web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }
  required init?(coder: NSCoder) { nil }
  private func fitCard() {
    guard let window, let screen = window.screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame
    let content = NSRect(x: 0, y: 0, width: min(Self.cardWidth, visible.width), height: cardHeight)
    var frame = window.frameRect(forContentRect: content)
    frame.size.height = min(frame.height, visible.height)
    frame.origin.x = window.frame.minX
    frame.origin.y = window.frame.maxY - frame.height
    frame = window.constrainFrameRect(frame, to: screen)
    if frame != window.frame { window.setFrame(frame, display: true) }
  }
  func windowDidChangeScreen(_ notification: Notification) { fitCard() }
  @objc func newDocument(_ sender: Any?) { start("new", nil) }
  @objc func openDocument(_ sender: Any?) {
    guard let window else { return }
    let picker = NSOpenPanel()
    picker.allowedContentTypes = [.gridnote, .pdf]
    picker.beginSheetModal(for: window) { [weak self] result in
      if result == .OK, let url = picker.url { self?.start("open", url) }
    }
  }
  func installMenus() {
    let bar = NSMenu()
    for name in ["Gridnote", "File", "Edit", "Window"] {
      let menu = NSMenu(title: name), top = NSMenuItem()
      top.submenu = menu; bar.addItem(top)
      switch name {
      case "Gridnote":
        menu.addItem(withTitle: "About Gridnote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Gridnote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
      case "File":
        menu.addItem(withTitle: "New Notebook", action: #selector(newDocument(_:)), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Open Notebook or PDF…", action: #selector(openDocument(_:)), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
      case "Edit":
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
      default: NSApp.windowsMenu = menu
      }
    }
    NSApp.mainMenu = bar
  }
  func dismiss() {
    web.configuration.userContentController.removeScriptMessageHandler(forName: "gridnoteLauncher")
    window?.orderOut(nil)
  }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
      let values = message.body as? [String: String], let action = values["action"] else { return }
    switch action {
    case "fit":
      guard let value = values["height"], let height = Double(value),
        height.isFinite, height > 0 else { return }
      cardHeight = CGFloat(height)
      fitCard()
    case "open": openDocument(nil)
    case "continue", "new": start(action, nil)
    default: break
    }
  }
}
