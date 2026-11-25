import AppKit

final class GridnoteDelegate: NSObject, NSApplicationDelegate {
  private let storage = NotebookStorage()
  private let preferences = PenPreferences()
  private var notebook: NotebookWindow?
  private var launcher: LauncherController?
  private var pendingFile: URL?
  private var ready = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    ready = true
    NSEvent.isMouseCoalescingEnabled = false
    if let url = pendingFile { pendingFile = nil; start("open", url) }
    else { showLauncher() }
    NSApp.activate(ignoringOtherApps: true)
  }

  private func showLauncher() {
    if let launcher { launcher.showWindow(nil); launcher.window?.makeKeyAndOrderFront(nil); return }
    guard notebook?.checkpoint() != false else { return }
    let last = notebook?.notebookURL ?? (try? storage.loadSession())?.lastNotebook
    preferences.detectDevice()
    let screen = LauncherController(preferences: preferences, last: last) { [weak self] action, url in
      self?.start(action, url)
    }
    launcher = screen
    screen.installMenus()
    notebook?.window?.orderOut(nil)
    screen.showWindow(nil)
    screen.window?.makeKeyAndOrderFront(nil)
  }

  private func start(_ action: String, _ url: URL?) {
    let editor = notebook ?? NotebookWindow(storage: storage, preferences: preferences)
    notebook = editor
    editor.requestLauncher = { [weak self] in self?.showLauncher() }
    launcher?.dismiss()
    launcher = nil
    Self.installMenus(editor)
    editor.showWindow(nil)
    editor.window?.makeKeyAndOrderFront(nil)
    switch action {
    case "open": if let url { editor.openFile(url) }
    case "new": editor.newNotebook(nil)
    default: if editor.notebookURL == nil { editor.restoreLastNotebook() }
    }
    editor.canvas.refreshTool()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let file = urls.first else { return }
    if ready { start("open", file) } else { pendingFile = file }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if let launcher { launcher.showWindow(nil); launcher.window?.makeKeyAndOrderFront(nil) }
    else if let editor = notebook, hasVisibleWindows { editor.window?.makeKeyAndOrderFront(nil) }
    else { showLauncher() }
    return true
  }

  func applicationDidResignActive(_ notification: Notification) {
    _ = notebook?.checkpoint(showError: false)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    notebook?.checkpoint() == false ? .terminateCancel : .terminateNow
  }

  static func installMenus(_ owner: NotebookWindow) {
    let menu = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let entry = NSMenuItem()
      let child = NSMenu(title: title)
      entry.submenu = child
      menu.addItem(entry)
      return child
    }
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
      _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target
      menu.addItem(item)
    }
    let app = submenu("Gridnote")
    add(app, "About Gridnote", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    add(app, "Options…", #selector(owner.openOptions(_:)), ",", target: owner)
    app.addItem(.separator())
    add(app, "Hide Gridnote", #selector(NSApplication.hide(_:)), "h")
    add(
      app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
      [.option, .command])
    add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
    app.addItem(.separator())
    add(app, "Quit Gridnote", #selector(NSApplication.terminate(_:)), "q")

    let file = submenu("File")
    add(file, "Notebook Launcher…", #selector(owner.notebookLauncher(_:)), target: owner)
    add(file, "New Notebook", #selector(owner.newNotebook(_:)), "n", target: owner)
    add(file, "Open Notebook or PDF…", #selector(owner.openAny(_:)), "o", target: owner)
    add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
    file.addItem(.separator())
    add(file, "Save", #selector(owner.saveNow(_:)), "s", target: owner)
    add(
      file, "Save Notebook As…", #selector(owner.saveAs(_:)), "s", [.shift, .command], target: owner
    )
    file.addItem(.separator())
    add(
      file, "Import Image…", #selector(owner.importImage(_:)), "i", [.shift, .command],
      target: owner)
    add(file, "Preview PDF", #selector(owner.previewPDF(_:)), "p", target: owner)
    add(
      file, "Export PDF…", #selector(owner.exportPDF(_:)), "e", [.shift, .command], target: owner)
    let edit = submenu("Edit")
    add(edit, "Undo", #selector(owner.undoEdit(_:)), "z", target: owner)
    add(edit, "Redo", #selector(owner.redoEdit(_:)), "z", [.shift, .command], target: owner)
    edit.addItem(.separator())
    add(edit, "Cut", #selector(NSText.cut(_:)), "x")
    add(edit, "Copy", #selector(NSText.copy(_:)), "c")
    add(edit, "Paste", #selector(NSText.paste(_:)), "v")
    add(edit, "Select All", #selector(NSResponder.selectAll(_:)), "a")
    add(edit, "Delete", #selector(NSText.delete(_:)))
    edit.addItem(.separator())
    add(edit, "Erase Selected Strokes", #selector(NoteCanvas.eraseSelectedStrokes(_:)))
    add(edit, "Clear Writing on This Page", #selector(owner.clearPage(_:)), target: owner)

    let cleanup = NSMenuItem(title: "Remove Typed Text", action: nil, keyEquivalent: "")
    cleanup.submenu = NSMenu(title: "Remove Typed Text")
    edit.addItem(cleanup)
    add(cleanup.submenu!, "This Page", #selector(owner.clearPageText(_:)), target: owner)
    add(cleanup.submenu!, "All Pages", #selector(owner.clearTypedText(_:)), target: owner)
    add(edit, "Clear Writing on All Pages", #selector(owner.clearAll(_:)), target: owner)
    add(edit, "Delete This Page", #selector(owner.deletePage(_:)), target: owner)

    let tools = submenu("Tools")
    add(tools, "Choose Major…", #selector(owner.notebookLauncher(_:)), target: owner)
    add(tools, NoteTool.brush.title, #selector(owner.brushTool(_:)), target: owner)
    add(tools, "Selector", #selector(owner.selectorTool(_:)), target: owner)
    add(tools, "Eraser", #selector(owner.eraserTool(_:)), target: owner)
    add(tools, "Highlighter", #selector(owner.markerTool(_:)), target: owner)
    add(tools, "Shapes", #selector(owner.shapesTool(_:)), target: owner)
    add(tools, "Table", #selector(owner.tableTool(_:)), target: owner)
    add(tools, "Text", #selector(owner.textTool(_:)), target: owner)
    tools.addItem(.separator())
    add(tools, "Tap Selection", #selector(owner.selectByTap(_:)), target: owner)
    add(tools, "Rectangle Selection", #selector(owner.selectByRectangle(_:)), target: owner)
    add(tools, "Freehand Lasso", #selector(owner.selectByLasso(_:)), target: owner)
    let view = submenu("View")
    add(view, "Page Thumbnails", #selector(owner.togglePages(_:)), target: owner)
    add(view, "Zoom In", #selector(owner.zoomIn(_:)), "=", target: owner)
    add(view, "Zoom Out", #selector(owner.zoomOut(_:)), "-", target: owner)
    add(view, "Fit Width", #selector(owner.fitWidth(_:)), "0", target: owner)
    add(view, "Toggle Color Palette", #selector(owner.togglePalette(_:)), target: owner)
    view.addItem(.separator())
    add(
      view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
      [.control, .command])
    let window = submenu("Window")
    add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
    NSApp.windowsMenu = window
    let help = submenu("Help")
    add(help, "Gridnote Guide", #selector(owner.quickGuide(_:)), target: owner)
    add(help, "Writing Device Controls", #selector(owner.wacomSetup(_:)), target: owner)
    NSApp.helpMenu = help
    NSApp.mainMenu = menu
  }
}
