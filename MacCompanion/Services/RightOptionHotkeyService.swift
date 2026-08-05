import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Companion-side fallback when the InputMethodKit source is not yet registered.
/// Captures Right Option (keyCode 61) globally and drives the same recording pipeline.
/// Requires: System Settings → Privacy & Security → Accessibility (and Input Monitoring on some macOS).
@MainActor
final class RightOptionHotkeyService {
    static let shared = RightOptionHotkeyService()

    private weak var coordinator: VoiceSessionCoordinator?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightOptionDown = false
    private var enabled = false

    private init() {}

    func bind(coordinator: VoiceSessionCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard !enabled else { return }
        enabled = true

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
            // Never consume locally in the companion UI; only IME should steal keys.
            return event
        }
        NSLog("RightOptionHotkeyService: monitors installed")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        enabled = false
        if rightOptionDown, let coordinator, coordinator.state == .recording {
            coordinator.cancelRecording()
        }
        rightOptionDown = false
    }

    /// Prompt once for Accessibility so global Right Option monitors can see key events outside this app.
    func ensureAccessibilityPrompt() {
        // Avoid Swift 6 concurrency complaint on CFString global kAXTrustedCheckOptionPrompt.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        NSLog("RightOptionHotkeyService: accessibility trusted=%@", trusted ? "yes" : "no")
    }

    private func handle(_ event: NSEvent) {
        guard let coordinator else { return }

        switch event.type {
        case .flagsChanged:
            // Right Option only (hardware keyCode 61). Ignore left Option.
            guard event.keyCode == UInt16(kVK_RightOption) else { return }
            let down = event.modifierFlags.contains(.option)
            if down && !rightOptionDown {
                rightOptionDown = true
                // Allow barge-in while previous segments are still recognizing / polishing.
                if coordinator.state != .inactive && coordinator.state != .recording {
                    coordinator.startRecording()
                }
            } else if !down && rightOptionDown {
                rightOptionDown = false
                if coordinator.state == .recording {
                    Task { @MainActor in
                        if let jobID = await coordinator.finishRecordingAndEnqueue() {
                            if let text = await coordinator.waitForJobResult(jobID), !text.isEmpty {
                                TextInserter.paste(text)
                            }
                        }
                    }
                }
            }
        case .keyDown:
            // Escape cancels an in-flight recording.
            if event.keyCode == UInt16(kVK_Escape), coordinator.state == .recording {
                coordinator.cancelRecording()
                rightOptionDown = false
            }
        default:
            break
        }
    }
}

enum TextInserter {
    /// Serialize multi-segment paste so concurrent jobs cannot clobber the clipboard.
    @MainActor
    private static var pasteChain: Task<Void, Never>?

    /// Best-effort insertion via clipboard + Cmd+V. Works in most text fields.
    @MainActor
    static func paste(_ text: String) {
        let previous = pasteChain
        pasteChain = Task { @MainActor in
            _ = await previous?.value
            await pasteNow(text)
        }
    }

    @MainActor
    private static func pasteNow(_ text: String) async {
        let pb = NSPasteboard.general
        let previous = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict.isEmpty ? nil : dict
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Small delay so the pasteboard settles before the synthetic paste.
        try? await Task.sleep(nanoseconds: 50_000_000)
        postCommandV()
        // Restore previous pasteboard after a beat so we don't clobber the user's clipboard forever.
        if let previous {
            try? await Task.sleep(nanoseconds: 400_000_000)
            pb.clearContents()
            for dict in previous {
                pb.writeObjects([NSPasteboardItem.from(dict)])
            }
        } else {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9 // kVK_ANSI_V
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private extension NSPasteboardItem {
    static func from(_ dict: [NSPasteboard.PasteboardType: Data]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, data) in dict {
            item.setData(data, forType: type)
        }
        return item
    }
}
