import AppKit
import WebKit

final class StudyInsertHandler: NSObject, WKScriptMessageHandler {
  var insert: ((String) -> Void)?
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
      let text = message.body as? String, !text.isEmpty, text.count <= 4096
    else { return }
    insert?(text)
  }
}

final class SubjectToolsController: NSViewController {
  let major: String
  let tool: String?
  let handler = StudyInsertHandler()
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
    let web = WKWebView(frame: .zero, configuration: config)
    view = web
    preferredContentSize = CGSize(
      width: major == "Chemistry" ? 646 : 455, height: major == "Chemistry" ? 460 : 395)
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
