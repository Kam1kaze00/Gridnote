import AppKit

final class PageSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
  let table = NSTableView()
  private let cache = NSCache<NSNumber, NSImage>()
  private var revision: UInt64?
  private var bookID: UUID?
  private var count = 0
  private var updating = false
  var thumbnail: ((Int) -> NSImage?)?
  var jump: ((Int) -> Void)?
  var action: ((String, Int) -> Void)?
  var reorder: ((Int, Int) -> Void)?
  private let dragType = NSPasteboard.PasteboardType("app.gridnote.page-row")
  private var buttons: [NSButton] = []
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = chromeToolbar.cgColor
    cache.countLimit = 96
    let col = NSTableColumn(identifier: .init("page"))
    col.minWidth = 90
    table.addTableColumn(col)
    table.headerView = nil
    table.rowHeight = 130
    table.backgroundColor = .clear
    table.registerForDraggedTypes([dragType])
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    table.dataSource = self
    table.delegate = self
    table.allowsEmptySelection = false
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = table
    let bar = chromeStack([], spacing: 3)
    for (idx, item) in [
      ("plus", "Insert page after"), ("arrow.up", "Move page earlier"),
      ("arrow.down", "Move page later"), ("trash", "Delete page"),
    ].enumerated() {
      let b = NSButton(
        image: NSImage(systemSymbolName: item.0, accessibilityDescription: item.1)!, target: self,
        action: #selector(performAction(_:)))
      b.bezelStyle = .accessoryBarAction
      b.tag = idx
      b.toolTip = item.1
      b.setAccessibilityLabel(item.1)
      bar.addArrangedSubview(b)
      buttons.append(b)
    }
    let title = chromeLabel("Pages", size: 13, weight: .semibold)
    for child in [title, scroll, bar] {
      child.translatesAutoresizingMaskIntoConstraints = false
      addSubview(child)
    }
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 5),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    setAccessibilityLabel("Page thumbnails")
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = chromeToolbar.cgColor
    }
  }
  required init?(coder: NSCoder) { nil }
  func update(_ book: Notebook, current: Int) {
    guard !isHidden else { return }
    updating = true
    defer { updating = false }
    if revision != book.revision || bookID != book.id || count != book.usedPages {
      revision = book.revision
      bookID = book.id
      count = book.usedPages
      cache.removeAllObjects()
      table.reloadData()
    }
    let row = min(max(0, current), count - 1)
    if row >= 0 && table.selectedRow != row {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      table.scrollRowToVisible(row)
    }
    buttons[1].isEnabled = row > 0
    buttons[2].isEnabled = row + 1 < count
  }
  func numberOfRows(in tableView: NSTableView) -> Int { count }
  func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
    let image = NSImageView()
    let key = NSNumber(value: row)
    if let cached = cache.object(forKey: key) {
      image.image = cached
    } else if let img = thumbnail?(row) {
      cache.setObject(img, forKey: key)
      image.image = img
    }
    image.imageScaling = .scaleProportionallyUpOrDown
    image.heightAnchor.constraint(equalToConstant: 104).isActive = true
    let label = chromeLabel(String(row + 1), size: 11)
    let stack = chromeStack([image, label], spacing: 2, horizontal: false)
    stack.alignment = .centerX
    return stack
  }
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
  {
    let item = NSPasteboardItem()
    item.setString(String(row), forType: dragType)
    return item
  }
  func tableView(
    _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
    proposedDropOperation operation: NSTableView.DropOperation
  ) -> NSDragOperation {
    guard info.draggingSource as? NSTableView === tableView else { return [] }
    tableView.setDropRow(row, dropOperation: .above)
    return .move
  }
  func tableView(
    _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
    dropOperation: NSTableView.DropOperation
  ) -> Bool {
    guard info.draggingSource as? NSTableView === tableView,
      let value = info.draggingPasteboard.string(forType: dragType), let source = Int(value)
    else { return false }
    let target = row > source ? row - 1 : row
    guard target != source, (0..<count).contains(target) else { return false }
    reorder?(source, target)
    return true
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    if !updating, table.selectedRow >= 0 { jump?(table.selectedRow) }
  }
  @objc private func performAction(_ b: NSButton) {
    if table.selectedRow >= 0 {
      action?(["insert", "up", "down", "delete"][b.tag], table.selectedRow)
    }
  }
}

extension PaperRenderer {
  func thumbnail(_ book: Notebook, page: Int) -> NSImage? {
    let w = 158
    let h = 224
    guard
      let c = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    let top = CGFloat(page) * paperSize.height
    c.scaleBy(x: CGFloat(w) / paperSize.width, y: -CGFloat(h) / paperSize.height)
    c.translateBy(x: 0, y: -top - paperSize.height)
    let area = CGRect(origin: CGPoint(x: 0, y: top), size: paperSize)
    draw(
      page: page, design: book.paper(on: page), sourceIndex: book.sourceIndex(on: page),
      originalScale: book.originalPDFScale == true, context: c)
    for o in book.objects where o.frame.intersects(area) { draw(o, context: c) }
    return c.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: 79, height: 112)) }
  }
}
