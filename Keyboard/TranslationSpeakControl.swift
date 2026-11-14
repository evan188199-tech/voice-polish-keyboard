import SwiftUI

/// Original UI implementing the verified interaction direction, not reference pixels.
/// The enclosing keyboard must disable page-swipes while onTracking reports true.
struct TranslationSpeakControl: View {
    let targets: [TranslationTarget]
    let canTranslate: Bool
    let isRecording: Bool
    let isBusy: Bool
    let needsActivation: Bool
    let onTap: () -> Void
    let onTranslate: (TranslationTarget) -> Void
    let onTracking: (Bool) -> Void
    @State private var began: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var drag: CGSize = .zero
    @State private var holdTask: Task<Void, Never>?
    @GestureState private var fingerDown = false
    private let selectionWidth: CGFloat = 264
    private var selected: Int? {
        TranslationSpeakGesture.selection(elapsed: elapsed, horizontal: Double(drag.width), vertical: Double(drag.height),
            width: Double(selectionWidth), targetCount: targets.count)
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    Text(target.displayName).font(.caption2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selected == index ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: selectionWidth, height: 44)
            .opacity(elapsed >= TranslationSpeakGesture.holdDuration && drag.height < 0 ? 1 : 0)
            .accessibilityHidden(true)
            ZStack {
                Circle().fill(needsActivation ? Color.clear : Color.primary)
                Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                if isBusy { ProgressView().tint(needsActivation ? Color.primary : Color(uiColor: .systemBackground)) }
                else {
                    Image(systemName: isRecording ? "waveform" : (needsActivation ? "mic" : "mic.fill"))
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(needsActivation ? Color.primary : Color(uiColor: .systemBackground))
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
            .gesture(gesture)
            .accessibilityLabel(isRecording ? "完成录音" : "Speak，说话")
            .accessibilityHint("单点普通听写；长按上滑选择翻译目标。也可使用翻译语言菜单。")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if !isBusy { onTap() } }
            Menu {
                ForEach(targets) { target in
                    Button("翻译为\(target.displayName)") { onTranslate(target) }.disabled(!canTranslate || isRecording || isBusy)
                }
                if !canTranslate { Text("翻译服务不可用，请先在主应用查看设置。") }
            } label: {
                Label("翻译语言", systemImage: "character.bubble").font(.caption).frame(minHeight: 44)
            }
            .accessibilityLabel("无障碍翻译入口，选择语言后录音")
        }
        .onChange(of: fingerDown) { _, down in if !down { reset() } }
        .onDisappear { reset() }
    }
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($fingerDown) { _, state, _ in state = true }
            .onChanged { value in
                guard !isBusy else { return }
                if began == nil {
                    began = value.time; onTracking(true)
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard !Task.isCancelled, began != nil else { return }
                        elapsed = max(elapsed, TranslationSpeakGesture.holdDuration)
                    }
                }
                elapsed = value.time.timeIntervalSince(began ?? value.time)
                drag = value.translation
            }
            .onEnded { value in
                guard !isBusy, let began else { reset(); return }
                let action = TranslationSpeakGesture.ended(elapsed: value.time.timeIntervalSince(began),
                    horizontal: Double(value.translation.width), vertical: Double(value.translation.height),
                    width: Double(selectionWidth), targetCount: targets.count, canTranslate: canTranslate && !isRecording)
                reset()
                switch action {
                case .dictate: onTap()
                case .translate(let index): onTranslate(targets[index])
                case .none: break
                }
            }
    }
    private func reset() {
        holdTask?.cancel(); holdTask = nil; began = nil; elapsed = 0; drag = .zero; onTracking(false)
    }
}
