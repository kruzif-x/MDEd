import Cocoa

// No storyboard/xib: build the application and its delegate entirely in code.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
