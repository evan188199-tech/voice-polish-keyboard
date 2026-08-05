import AppKit

final class InputMethodAppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static let shared = InputMethodAppDelegate()

    private override init() {
        super.init()
        NSApp.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock UI; overlay is created on demand by the input controller.
    }
}
