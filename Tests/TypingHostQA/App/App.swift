import UIKit

@main final class AppDelegate: UIResponder, UIApplicationDelegate {}
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = HostVC()
        self.window = window
        window.makeKeyAndVisible()
    }
}

final class HostVC: UIViewController, UITextFieldDelegate {
    private let sendReceipt = UILabel()
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendReceipt.text = textField.text
        return false
    }
    let field = UITextField(), prose = UITextView()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        field.text = "Alpha Alice Omega"; field.borderStyle = .roundedRect; field.accessibilityIdentifier = "host.field"
        field.returnKeyType = .send; field.delegate = self
        sendReceipt.accessibilityIdentifier = "host.localSend"
        prose.text = "前文周五联系 Alice。后文"; prose.accessibilityIdentifier = "host.prose"
        prose.backgroundColor = .secondarySystemBackground
        prose.font = UIFont.preferredFont(forTextStyle: .body)
        let select = UIButton(type: .system)
        select.setTitle("选中 Alice", for: .normal); select.accessibilityIdentifier = "host.select"
        select.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.field.becomeFirstResponder()
            let start = self.field.position(from: self.field.beginningOfDocument, offset: 6)!
            let end = self.field.position(from: start, offset: 5)!
            self.field.selectedTextRange = self.field.textRange(from: start, to: end)
        }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [select,field,prose,sendReceipt])
        stack.spacing = 16; stack.axis = .vertical; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            prose.heightAnchor.constraint(equalToConstant: 90)
        ])
    }
}
