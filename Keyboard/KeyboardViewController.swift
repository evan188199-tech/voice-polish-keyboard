import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardView>?
    private let viewModel = KeyboardViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Passive clipboard sample: one value per keyboard appearance (no background
        // monitoring possible). Requires Full Access; silently skips otherwise.
        if hasFullAccess {
            _ = ClipboardCapture.captureIfNeeded()
        }
        viewModel.appear()
        viewModel.onTextReady = { [weak self] text in
            guard let self, self.view.window != nil else { return }
            self.textDocumentProxy.insertText(text)
        }
        Task { await viewModel.connect() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        viewModel.onTextReady = nil
        viewModel.disconnect()
    }

    private func setupKeyboard() {
        (view as? UIInputView)?.allowsSelfSizing = true
        inputView?.allowsSelfSizing = true

        let keyboard = KeyboardView(
            model: viewModel,
            onInsert: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            onDelete: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onReturn: { [weak self] in
                self?.textDocumentProxy.insertText("\n")
            },
            onActivateSession: { [weak self] in
                self?.openHostAndActivateSession()
            },
            onNextKeyboard: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )

        let host = UIHostingController(rootView: keyboard)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: KeyboardLayout.contentHeight)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        host.didMove(toParent: self)
        self.host = host
    }

    private func openHostAndActivateSession() {
        var components = URLComponents()
        components.scheme = "voicepolish"
        components.host = "activate-session"
        var queryItems = [URLQueryItem(name: "return", value: "keyboard-host")]
        if let hostBundleID = keyboardHostBundleIdentifier() {
            queryItems.append(URLQueryItem(name: "hostBundleID", value: hostBundleID))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            return
        }
        extensionContext?.open(url) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.openURLThroughResponderChain(url)
            }
        }
    }

    /// Best-effort private probe. There is no public host-app API for third-party
    /// keyboards, but the host identifier is available on the presentation parent
    /// or extension context on current iOS releases.
    private func keyboardHostBundleIdentifier() -> String? {
        var objects: [NSObject] = []
        if let parent {
            objects.append(parent)
        }
        if let extensionContext {
            objects.append(extensionContext)
        }
        let selectorNames = [
            "_hostBundleID",
            "hostBundleID",
            "_hostBundleIdentifier",
            "hostBundleIdentifier",
            "_hostIdentifier",
            "hostIdentifier"
        ]

        for object in objects {
            for name in selectorNames {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector),
                      let value = object.perform(selector)?.takeUnretainedValue() as? String
                else { continue }
                if isUsableHostBundleIdentifier(value) {
                    return value
                }
            }
        }
        return nil
    }

    private func isUsableHostBundleIdentifier(_ value: String) -> Bool {
        value.contains(".")
            && value != "com.voicepolish.app"
            && value != "com.voicepolish.app.keyboard"
            && !value.hasPrefix("com.apple.UIKit")
    }

    /// Fallback for iOS builds that reject NSExtensionContext.open(_:).
    private func openURLThroughResponderChain(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }
}
