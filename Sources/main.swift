import AppKit

let application = NSApplication.shared
let delegate = GridnoteDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
