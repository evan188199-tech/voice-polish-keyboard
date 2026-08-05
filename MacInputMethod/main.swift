import Foundation
import AppKit
import InputMethodKit

// Force-link controller for IMK class lookup via Info.plist.
_ = VoicePolishInputController.self

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
_ = InputMethodAppDelegate.shared

let bundleID = Bundle.main.bundleIdentifier ?? "com.voicepolish.inputmethod"
let connectionName = (Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String)
    ?? "com.voicepolish.inputmethod.IMK_Connection"

// Keep strong reference for process lifetime. Connection registration can fail when
// launched outside the input-method host; do not abort the process for that.
let server: IMKServer? = IMKServer(name: connectionName, bundleIdentifier: bundleID)
if server == nil {
    NSLog("VoicePolishInputMethod: IMKServer failed for \(connectionName)")
}

app.run()
