import AppKit

/// Non-activating floating status pill near the bottom of the main screen.
@MainActor
final class StatusOverlayController {
    static let shared = StatusOverlayController()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    /// Show status. Error messages auto-hide after 2.4s; normal ones keep visible until replaced/hidden
    /// unless `autoHideAfter` is provided (or positive for sticky states like recording).
    func show(_ text: String, isError: Bool = false, autoHideAfter: TimeInterval? = nil) {
        let panel = ensurePanel()
        label?.stringValue = text
        label?.textColor = isError ? .systemRed : .labelColor
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let delay: TimeInterval?
        if let autoHideAfter {
            delay = autoHideAfter
        } else if isError {
            delay = 2.4
        } else {
            // Default: transient info auto-hides; recording/recognizing stay until next update.
            let sticky = text.contains("录音") || text.contains("识别") || text.contains("润色") || text.contains("生成")
            delay = sticky ? nil : 1.2
        }
        guard let delay, delay > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let container = NSView(frame: panel.contentView!.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        container.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        ])

        panel.contentView = container
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - 140
            let y = frame.minY + 48
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        self.panel = panel
        self.label = label
        return panel
    }
}
