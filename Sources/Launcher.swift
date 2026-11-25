import AppKit
import JavaScriptCore
import UniformTypeIdentifiers
import WebKit

enum MajorCatalog {
  static let tools: [String: [String]] = {
    let url = Bundle.main.url(forResource: "majors", withExtension: "js")
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("web/majors.js")
    guard let source = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return [:] }
    context.evaluateScript(source)
    return context.evaluateScript("Object.fromEntries(Object.entries(GridnoteKits.kits).map(([name,tools]) => [name,tools.map(t=>t.name)]))")?.toDictionary() as? [String: [String]] ?? [:]
  }()
}

final class LauncherController: NSWindowController, WKScriptMessageHandler {
  private let prefs: PenPreferences
  private let start: (String, URL?) -> Void
  private var web: WKWebView!
  init(preferences: PenPreferences, last: URL?, start: @escaping (String, URL?) -> Void) {
    prefs = preferences
    ChromeTheme.cartoon = preferences.cartoonTheme
    self.start = start
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Gridnote"
    window.minSize = NSSize(width: 375, height: 420)
    window.appearance = ChromeTheme.appearance
    window.center()
    super.init(window: window)
    let config = WKWebViewConfiguration()
    let options: [String: Any] = ["theme": prefs.cartoonTheme ? "70s Cartoon" : "Default", "major": prefs.major, "device": prefs.deviceDescription,
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
    case "theme":
      guard let theme = values["theme"], ["Default", "70s Cartoon"].contains(theme) else { return }
      prefs.cartoonTheme = theme == "70s Cartoon"
      ChromeTheme.cartoon = prefs.cartoonTheme
      window?.appearance = ChromeTheme.appearance
    case "major": if let major = values["major"] { prefs.major = major }
    case "open": openDocument(nil)
    case "continue", "new": start(action, nil)
    default: break
    }
  }
}
