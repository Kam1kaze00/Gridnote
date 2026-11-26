import UIKit
import WebKit

final class NotebookViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private var editor: BundledEditor?
    private var origin: URL?
    private var webView: WKWebView!
    private var downloads: [ObjectIdentifier: URL] = [:]
    private let paperChrome = UIColor(red: 0.10, green: 0.13, blue: 0.15, alpha: 1)
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paperChrome
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.applicationNameForUserAgent = "Gridnote-iPad/1"
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = paperChrome
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
        begin()
    }

    private func begin() {
        guard let root = Bundle.main.url(forResource: "public", withExtension: nil) else {
            showError("The notebook editor is missing from this installation."); return
        }
        let editor = BundledEditor(root: root)
        self.editor = editor
        editor.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let origin):
                self.origin = origin
                self.webView.load(URLRequest(url: origin))
            case .failure:
                self.showError("The notebook could not open its local storage address. Your saved work stays on this iPad.") { self.begin() }
            }
        }
    }

    private func showError(_ message: String, retry: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "Gridnote", message: message, preferredStyle: .alert)
        if let retry { alert.addAction(UIAlertAction(title: "Try again", style: .default) { _ in retry() }) }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        (presentedViewController ?? self).present(alert, animated: true)
    }

    private func local(_ url: URL?) -> Bool {
        guard let url, let origin else { return false }
        return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port && (url.path == "/app" || url.path.hasPrefix("/app/"))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload && url.scheme == "blob" && local(action.sourceFrame.request.url) {
            decisionHandler(.download)
        } else if local(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated && url.scheme == "https" {
                UIApplication.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url, local(url) else { return nil }
        let help = UIViewController()
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        help.view = browser
        help.title = "Gridnote Help"
        help.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(UINavigationController(rootViewController: help), animated: true)
        return browser
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = (suggestedFilename as NSString).lastPathComponent
        guard !filename.isEmpty, !filename.hasPrefix(".") else { completionHandler(nil); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(filename)
            downloads[ObjectIdentifier(download)] = file
            completionHandler(file)
        } catch { completionHandler(nil); showError("There is not enough space to export this file.") }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let anchor = share.popoverPresentationController {
            anchor.sourceView = view
            anchor.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 36, width: 1, height: 1)
        }
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        guard presentedViewController == nil else {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            showError("Close the current sheet and export again."); return
        }
        present(share, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloads.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        showError("Export failed. \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
}
