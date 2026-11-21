import UIKit
import SwiftUI

final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardView>?
    private let typing = ManualTypingCandidates()
    private var typingVisit = UUID()
    private let pinyin = PinyinComposition()
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
        Task { await viewModel.connect() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        typingVisit = UUID()
        typing.refresh()
        pinyin.clear()
        typing.setActive(false)
        viewModel.disconnect()
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        typingVisit = UUID()
        typing.refresh()
        pinyin.clear()
        super.textWillChange(textInput)
    }

    override func selectionWillChange(_ textInput: (any UITextInput)?) {
        typingVisit = UUID()
        typing.refresh()
        pinyin.clear()
        super.selectionWillChange(textInput)
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        typing.refresh()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        typing.refresh()
    }

    private func setupKeyboard() {
        (view as? UIInputView)?.allowsSelfSizing = true
        inputView?.allowsSelfSizing = true

        pinyin.currentDocument = { [weak self] in (self?.textDocumentProxy as AnyObject?)?.perform(#selector(getter: UITextDocumentProxy.documentIdentifier))?.takeUnretainedValue() as? UUID }
        typing.readContext = { [weak self] in
            guard let self, let document = self.pinyin.currentDocument(), self.view.window != nil else { return nil }
            let proxy = self.textDocumentProxy
            let contentType = proxy.textContentType ?? nil
            guard proxy.isSecureTextEntry != true, proxy.autocorrectionType != .no, contentType?.rawValue.isEmpty != false,
                  proxy.keyboardType == nil || proxy.keyboardType == .default || proxy.keyboardType == .asciiCapable,
                  proxy.selectedText?.isEmpty != false, let before = proxy.documentContextBeforeInput else { return nil }
            return ManualTypingContext(ticket: self.typingVisit, document: document, before: before, after: proxy.documentContextAfterInput ?? "")
        }
        typing.replaceSuffix = { [weak self] count, value in
            guard let proxy = self?.textDocumentProxy else { return }
            for _ in 0..<count { proxy.deleteBackward() }
            if !value.isEmpty { proxy.insertText(value) }
        }
        let keyboard = KeyboardView(
            model: viewModel,
            typing: typing,
            pinyin: pinyin,
            onInsert: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
                self?.typing.refresh()
            },
            onDelete: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
                self?.typing.refresh()
            },
            onReturn: { [weak self] in
                self?.textDocumentProxy.insertText("\n")
            },
            onActivateSession: { [weak self] in
                self?.openHostAndActivateSession()
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
