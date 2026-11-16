import AppKit
import GhosttyKit

Startup.mark("main")
let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
