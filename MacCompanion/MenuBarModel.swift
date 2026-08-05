import Foundation
import Combine
import SwiftUI

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var title = "语音"
    @Published var symbolName = "mic"
    private var coordinator: VoiceSessionCoordinator?

    func bind(coordinator: VoiceSessionCoordinator) {
        self.coordinator = coordinator
        // Poll lightweight status for menu label.
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let coordinator = self.coordinator else { return }
                self.apply(state: coordinator.state, message: coordinator.statusMessage)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func apply(state: BridgeStatus.State, message: String?) {
        switch state {
        case .inactive:
            title = "未启动"
            symbolName = "mic.slash"
        case .ready:
            title = "就绪"
            symbolName = "mic"
        case .recording:
            title = "录音中"
            symbolName = "mic.fill"
        case .transcribing:
            title = "识别中"
            symbolName = "waveform"
        case .polishing:
            title = message ?? "润色中"
            symbolName = "sparkles"
        case .error:
            title = "错误"
            symbolName = "exclamationmark.triangle"
        }
        _ = message
    }
}
