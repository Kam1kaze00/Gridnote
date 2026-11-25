import AppKit
import PDFKit

final class PenSettingsController: NSViewController {
  private let preferences: PenPreferences
  var didRestore: (() -> Void)?
  private let setup: () -> Void
  private var values: [NSTextField] = []
  private var sliders: [NSSlider] = []

  init(
    preferences: PenPreferences, setup: @escaping () -> Void
  ) {
    self.preferences = preferences
    self.setup = setup
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = CGSize(width: 295, height: 195)
  }
  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = Surface(chromeToolbar)
    let labels = ["Pen scroll speed"]
    let limits = [(0.12, 0.65)]
    let starting = [preferences.scrollSpeed]
    let heading = chromeLabel("Options", size: 16, weight: .semibold)
    let device = chromeLabel(preferences.deviceDescription, size: 12, color: chromeMuted)
    let stack = chromeStack([heading, device], spacing: 11, horizontal: false)
    view.addSubview(stack)
    for index in labels.indices {
      let label = chromeLabel(labels[index], size: 12, weight: .medium)
      let value = chromeLabel("", size: 11, color: chromeMuted)
      values.append(value)
      let slider = NSSlider(
        value: starting[index], minValue: limits[index].0, maxValue: limits[index].1,
        target: self, action: #selector(changed(_:)))
      slider.tag = index
      slider.isContinuous = true
      slider.controlSize = .small
      slider.altIncrementValue = 0.01
      slider.setAccessibilityLabel(labels[index])
      sliders.append(slider)
      let line = chromeStack([label, NSView(), value])
      line.widthAnchor.constraint(equalToConstant: 255).isActive = true
      slider.widthAnchor.constraint(equalToConstant: 255).isActive = true
      stack.addArrangedSubview(chromeStack([line, slider], spacing: 3, horizontal: false))
      display(index)
    }
    let help = ChromeButton(
      "Device controls", symbol: "questionmark.circle", style: .outlined, target: self,
      action: #selector(openSetup))
    stack.addArrangedSubview(help)
    stack.addArrangedSubview(
      NSButton(title: "Restore all settings", target: self, action: #selector(restoreAll)))
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 17),
    ])
  }

  private func display(_ index: Int) {
    let value = sliders[index].doubleValue
    values[index].stringValue = String(format: "%.2f×", value)
  }

  @objc private func changed(_ slider: NSSlider) {
    let value = (slider.doubleValue * 100).rounded() / 100
    preferences.scrollSpeed = value
    display(slider.tag)
  }
  @objc private func restoreAll() {
    preferences.restore()
    sliders[0].doubleValue = preferences.scrollSpeed
    display(0)
    didRestore?()
  }
  @objc private func openSetup() { setup() }
}

final class PDFPreviewController: NSWindowController, NSWindowDelegate {
  var onClose: ((Bool) -> Void)?
  private var pdfData: Data
  private var shareName: String
  private var sharing: NSSharingServicePicker?
  init?(data: Data, parentSize: CGSize, page: Int = 0, name: String = "Notebook") {
    pdfData = data
    shareName = name
    guard let document = PDFDocument(data: data) else { return nil }
    let rect = CGRect(
      x: 0, y: 0, width: min(820, parentSize.width - 60), height: min(760, parentSize.height - 85))
    let panel = NSWindow(
      contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.isReleasedWhenClosed = false
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.title = "PDF Preview"
    panel.delegate = self
    panel.collectionBehavior.insert(.fullScreenAuxiliary)
    let root = Surface(chromeBackground)
    panel.contentView = root
    let pdf = PDFView()
    pdf.translatesAutoresizingMaskIntoConstraints = false
    pdf.displayMode = .singlePageContinuous
    pdf.displayDirection = .vertical
    pdf.displayBox = .mediaBox
    pdf.document = document
    pdf.autoScales = true
    root.addSubview(pdf)
    let count = chromeLabel(
      "A4  ·  \(document.pageCount) \(document.pageCount == 1 ? "page" : "pages")", size: 12,
      color: chromeMuted)
    let close = ChromeButton(
      "Close", style: .outlined, target: self, action: #selector(closePreview))
    close.keyEquivalent = "\u{1b}"
    let export = ChromeButton(
      "Export PDF…", symbol: "square.and.arrow.up", style: .primary, target: self,
      action: #selector(exportPreview))
    let share = ChromeButton(
      "Share", symbol: "square.and.arrow.up", style: .outlined, target: self,
      action: #selector(sharePDF(_:)))
    share.setAccessibilityLabel("Share PDF")
    let row = chromeStack([count, NSView(), close, share, export], spacing: 8)
    root.addSubview(row)
    NSLayoutConstraint.activate([
      pdf.topAnchor.constraint(equalTo: root.topAnchor),
      pdf.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      pdf.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      pdf.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -9),
      row.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
      row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 15),
      row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -13),
    ])
    root.layoutSubtreeIfNeeded()
    if let initial = document.page(at: min(max(0, page), document.pageCount - 1)) {
      pdf.go(to: initial)
    }
  }
  required init?(coder: NSCoder) { nil }
  @objc private func sharePDF(_ sender: NSView) {
    do {
      let fm = FileManager.default
      let base = fm.temporaryDirectory.appendingPathComponent("Gridnote-Share", isDirectory: true)
      let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      let safe = String(shareName.replacingOccurrences(of: "/", with: "-").prefix(110))
      let url = folder.appendingPathComponent((safe.isEmpty ? "Notebook" : safe) + ".pdf")
      try pdfData.write(to: url, options: .atomic)
      let picker = NSSharingServicePicker(items: [url])
      sharing = picker
      picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      for item
        in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey]))
        ?? []
      {
        if let d = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate,
          d.timeIntervalSinceNow < -86400
        {
          try? fm.removeItem(at: item)
        }
      }
    } catch { window?.presentError(error) }
  }
  @objc private func closePreview() { onClose?(false) }
  @objc private func exportPreview() { onClose?(true) }
}
