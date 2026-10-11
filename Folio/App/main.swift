import AppKit

// AppKit entry point: windows, toolbar, menus and tabs are AppKit; SwiftUI fills the inspector,
// settings panes and sheets (see doc/开发计划-v2.md).
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
