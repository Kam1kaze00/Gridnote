import AppKit
import WebKit

final class StudyInsertHandler: NSObject, WKScriptMessageHandler {
  var insert: ((String) -> Void)?
  var resize: ((CGFloat, Bool) -> Void)?
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true else { return }
    if message.name == "gridnoteSize" {
      guard let data = message.body as? [String: Any], let height = data["height"] as? Double,
        height.isFinite, height > 0, let periodic = data["periodic"] as? Bool else { return }
      resize?(CGFloat(height), periodic)
      return
    }
    guard let text = message.body as? String, !text.isEmpty, text.count <= 4096 else { return }
    insert?(text)
  }
}

final class SubjectToolsController: NSViewController {
  let major: String
  let tool: String?
  let handler = StudyInsertHandler()
  var didResize: ((CGSize) -> Void)?
  init(major: String, tool: String? = nil, insert: @escaping (String) -> Void) {
    self.major = major
    self.tool = tool
    super.init(nibName: nil, bundle: nil)
    handler.insert = insert
  }
  required init?(coder: NSCoder) { nil }
  override func loadView() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.add(handler, name: "gridnoteInsert")
    config.userContentController.add(handler, name: "gridnoteSize")
    let web = WKWebView(frame: .zero, configuration: config)
    view = web
    preferredContentSize = CGSize(width: tool == "Periodic table" ? 646 : 455, height: 245)
    handler.resize = { [weak self] height, periodic in
      guard let self else { return }
      let size = CGSize(width: periodic ? 646 : 455, height: min(ceil(height), 520))
      guard size != self.preferredContentSize else { return }
      self.preferredContentSize = size
      self.didResize?(size)
    }
    let url =
      Bundle.main.url(forResource: "subjects", withExtension: "html")
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("web/subjects.html")
    var parts = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true)
    var query = [URLQueryItem(name: "theme", value: ChromeTheme.current.rawValue)]
    if let tool { query.append(URLQueryItem(name: "tool", value: tool)) }
    parts?.queryItems = query
    parts?.fragment = major
    if let target = parts?.url {
      web.loadFileURL(target, allowingReadAccessTo: url.deletingLastPathComponent())
    }
  }
}
