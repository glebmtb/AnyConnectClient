import AppKit

let application = NSApplication.shared
let delegate = MenuBarAppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
