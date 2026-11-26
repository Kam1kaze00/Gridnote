import AppKit

final class PageSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
  static let openWidth: CGFloat = 136
  let table = NSTableView()
  private final class Preview: NSObject {
    let paper: PaperDesign
    let source: Int?
    let originalScale: Bool
    let objects: [NoteObject]
    let image: NSImage
    var revision: UInt64
    init(book: Notebook, page: Int, objects: [NoteObject], image: NSImage) {
      paper = book.paper(on: page)
      source = book.sourceIndex(on: page)
      originalScale = book.originalPDFScale == true
      revision = book.revision
      self.objects = objects
      self.image = image
    }
  }
  private let cache = NSCache<NSNumber, Preview>()
  private var notebook: Notebook?
  private var count = 0
  private var currentPage = 0
  private var updating = false
  var thumbnail: ((Int, [NoteObject]) -> NSImage?)?
  var jump: ((Int) -> Void)?
  var action: ((String, Int) -> Void)?
  var reorder: ((Int, Int) -> Void)?
  private let dragType = NSPasteboard.PasteboardType("app.gridnote.page-row")
  private var buttons: [NSButton] = []
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = chromeToolbar.cgColor
    cache.countLimit = 24
    let col = NSTableColumn(identifier: .init("page"))
    col.minWidth = 90
    col.resizingMask = .autoresizingMask
    table.addTableColumn(col)
    table.style = .plain
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.intercellSpacing = NSSize(width: 0, height: 2)
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
    let inset: CGFloat = 10
    let bar = chromeStack([], spacing: 4)
    bar.distribution = .fillEqually
    for (idx, item) in [
      ("plus", "Insert page after"), ("arrow.up", "Move page earlier"),
      ("arrow.down", "Move page later"), ("trash", "Delete page"),
    ].enumerated() {
      let b = ChromeButton(symbol: item.0, style: .outlined, target: self,
        action: #selector(performAction(_:)))
      b.controlWidth = (Self.openWidth - 2 * inset - 3 * bar.spacing) / 4
      b.controlHeight = 26
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
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      bar.widthAnchor.constraint(equalToConstant: Self.openWidth - 2 * inset),
      scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    setAccessibilityLabel("Page thumbnails")
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshPalette()
  }
  func refreshPalette() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = chromeToolbar.cgColor
    }
  }
  required init?(coder: NSCoder) { nil }
  func resetNotebook() {
    notebook = nil
    cache.removeAllObjects()
  }
  func update(_ book: Notebook, current: Int) {
    guard !isHidden else {
      if notebook != nil { resetNotebook() }
      return
    }
    updating = true
    defer { updating = false }
    let newBook = notebook?.id != book.id
    if newBook || notebook?.revision != book.revision {
      let previousCount = count
      if newBook { cache.removeAllObjects() }
      notebook = book
      count = book.usedPages
      if newBook || previousCount != count {
        table.reloadData()
      } else {
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound {
          for row in visible.location..<NSMaxRange(visible) {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
              cell.imageView?.image = image(for: row)
            }
          }
        }
      }
    }
    currentPage = current
    let used = (0..<count).contains(current)
    table.allowsEmptySelection = !used
    if used && table.selectedRow != current {
      table.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
      table.scrollRowToVisible(current)
    } else if !used && table.selectedRow >= 0 {
      table.deselectAll(nil)
    }
    let addLabel = used ? "Insert page after" : "Add this page"
    buttons[0].toolTip = addLabel
    buttons[0].setAccessibilityLabel(addLabel)
    buttons[0].isEnabled = used ? count < 99999 : current >= 0 && current < 99999
    buttons[1].isEnabled = used && current > 0
    buttons[2].isEnabled = used && current + 1 < count
    buttons[3].isEnabled = used
  }
  func numberOfRows(in tableView: NSTableView) -> Int { count }
  private func image(for row: Int) -> NSImage? {
    guard let book = notebook else { return nil }
    let key = NSNumber(value: row)
    let cached = cache.object(forKey: key)
    if let cached, cached.revision == book.revision { return cached.image }
    let area = CGRect(origin: CGPoint(x: 0, y: CGFloat(row) * paperSize.height), size: paperSize)
    let objects = book.objects.filter { $0.frame.intersects(area) }
    if let cached, cached.paper == book.paper(on: row), cached.source == book.sourceIndex(on: row),
       cached.originalScale == (book.originalPDFScale == true), cached.objects == objects {
      cached.revision = book.revision
      return cached.image
    }
    guard let result = thumbnail?(row, objects) else { return nil }
    cache.setObject(Preview(book: book, page: row, objects: objects, image: result), forKey: key)
    return result
  }
  func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
    let image = NSImageView()
    image.image = self.image(for: row)
    image.imageScaling = .scaleProportionallyUpOrDown
    image.heightAnchor.constraint(equalToConstant: 104).isActive = true
    let label = chromeLabel(String(row + 1), size: 11)
    let stack = chromeStack([image, label], spacing: 2, horizontal: false)
    stack.alignment = .centerX
    let cell = NSTableCellView()
    cell.imageView = image
    cell.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
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
    if b.tag == 0 && currentPage >= count {
      action?("add", currentPage)
    } else if table.selectedRow >= 0 {
      action?(["insert", "up", "down", "delete"][b.tag], table.selectedRow)
    }
  }
}

extension PaperRenderer {
  func thumbnail(_ book: Notebook, page: Int, objects: [NoteObject]) -> NSImage? {
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
    draw(
      page: page, design: book.paper(on: page), sourceIndex: book.sourceIndex(on: page),
      originalScale: book.originalPDFScale == true, context: c)
    for o in objects { draw(o, context: c) }
    return c.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: 79, height: 112)) }
  }
}
