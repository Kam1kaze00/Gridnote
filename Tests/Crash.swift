import AppKit

@main struct CrashCheckpoint {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 3 else { exit(2) }
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: args[2], isDirectory: true)
    let owner = NotebookWindow(
      storage: NotebookStorage(directory: root),
      preferences: PenPreferences(defaults: UserDefaults(suiteName: "GridnoteCrashTest")!),
      clipboard: .withUniqueName())
    owner.window?.orderFront(nil)
    let canvas = owner.canvas
    if args[1] == "verify" {
      owner.restoreLastNotebook()
      guard owner.notebookURL != nil, canvas.tool == .text,
        canvas.editor?.string == "Lecture draft before process loss",
        canvas.editor?.selectedRange().location == 8
      else { exit(1) }
      print("PASS restored live typing and caret after SIGKILL")
      return
    }
    owner.newNotebook(nil)
    canvas.chooseTool(.text)
    let at = canvas.convert(CGPoint(x: 84, y: 65), to: nil)
    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: at, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.window!.windowNumber,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    canvas.mouseDown(with: event)
    guard let editor = canvas.editor else { exit(1) }
    editor.insertText(
      "Lecture draft before process loss", replacementRange: NSRange(location: 0, length: 0))
    editor.setSelectedRange(NSRange(location: 8, length: 0))
    RunLoop.main.run(until: Date().addingTimeInterval(1.1))
    try Data().write(to: root.appendingPathComponent("ready"))
    withExtendedLifetime(owner) { RunLoop.main.run() }
  }
}
