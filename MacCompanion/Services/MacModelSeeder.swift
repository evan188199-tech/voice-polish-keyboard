import Foundation

enum MacModelSeeder {
    /// Copy Vendor/Models SenseVoice into Application Support when missing.
    static func seedIfNeeded() async {
        let dest = SenseVoiceTranscriber.defaultModelDirectory()
        let model = dest.appendingPathComponent("model.int8.onnx")
        let tokens = dest.appendingPathComponent("tokens.txt")
        if FileManager.default.fileExists(atPath: model.path),
           FileManager.default.fileExists(atPath: tokens.path) {
            return
        }

        // Prefer repo Vendor path relative to running app only in dev; otherwise skip.
        let candidates: [URL] = {
            var urls: [URL] = []
            if let exec = Bundle.main.executableURL {
                // .../MacCompanion.app/Contents/MacOS -> climb to repo Vendor in dev layouts is unreliable.
                _ = exec
            }
            // Well-known local checkout path used during self-use install.
            let home = FileManager.default.homeDirectoryForCurrentUser
            urls.append(home.appendingPathComponent("Documents/github/voice-polish-keyboard/Vendor/Models/\(AppConstants.senseVoiceModelName)"))
            // Install script may copy into Application Support seed/
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            urls.append(support.appendingPathComponent("VoicePolishKeyboard/Seed/\(AppConstants.senseVoiceModelName)"))
            return urls
        }()

        for src in candidates {
            let srcModel = src.appendingPathComponent("model.int8.onnx")
            let srcTokens = src.appendingPathComponent("tokens.txt")
            guard FileManager.default.fileExists(atPath: srcModel.path),
                  FileManager.default.fileExists(atPath: srcTokens.path) else { continue }
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: model.path) {
                    try FileManager.default.removeItem(at: model)
                }
                if FileManager.default.fileExists(atPath: tokens.path) {
                    try FileManager.default.removeItem(at: tokens)
                }
                try FileManager.default.copyItem(at: srcModel, to: model)
                try FileManager.default.copyItem(at: srcTokens, to: tokens)
                return
            } catch {
                continue
            }
        }
    }
}
