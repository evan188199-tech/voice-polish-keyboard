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
        Task { await viewModel.connect() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A third-party keyboard cannot safely replace text after its host
        // cursor has moved. Commit the marked raw draft and release the job.
        if viewModel.activeDraft != nil {
            textDocumentProxy.unmarkText()
            Task { await viewModel.abandonActiveDraft() }
        }
        viewModel.disconnect()
    }

    private func setupKeyboard() {
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
            onSetMarkedText: { [weak self] text in
                guard let self else { return }
                self.textDocumentProxy.setMarkedText(
                    text,
                    selectedRange: NSRange(location: text.utf16.count, length: 0)
                )
            },
            onUnmarkText: { [weak self] in
                self?.textDocumentProxy.unmarkText()
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
        host.didMove(toParent: self)
        self.host = host
    }
}
