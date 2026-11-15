import SwiftUI

@main struct VoiceUIHarnessApp: App {
    @State private var text = ""
    var body: some Scene {
        WindowGroup {
            VStack {
                Text("Keyboard QA")
                TextField("Test input", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("qa.input")
            }.padding()
        }
    }
}
