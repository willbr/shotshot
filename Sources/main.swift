import AppKit

// Entry point (equivalent to the old main.m)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement (menubar-only agent)

// Initialize controllers directly (more reliable than relying solely on
// applicationDidFinishLaunching when the binary is exec'd from the shell).
delegate.setup()

app.run()
