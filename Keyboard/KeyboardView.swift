import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var model: KeyboardViewModel
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onReturn: () -> Void
    let onActivateSession: () -> Void

    @State private var page: KeyboardPage = .voice
    @State private var dragX: CGFloat = 0
    @State private var pressed = false

    private let cancelThreshold: CGFloat = -60
    private let keyboardHeight: CGFloat = 294

    private static let quickSymbols: [(character: String, accessibilityLabel: String)] = [
        ("@", "at 符号"),
        ("#", "井号"),
        ("$", "美元符号"),
        ("¥", "人民币符号"),
        ("&", "and 符号"),
        ("*", "星号"),
        ("/", "斜杠"),
        ("_", "下划线")
    ]

    private static let numberPadRows: [[(character: String, accessibilityLabel: String)]] = [
        [("1", "1"), ("2", "2"), ("3", "3")],
        [("4", "4"), ("5", "5"), ("6", "6")],
        [("7", "7"), ("8", "8"), ("9", "9")],
        [(".", "小数点"), ("0", "0"), (",", "逗号")]
    ]

    var body: some View {
        VStack(spacing: 8) {
            if page == .voice {
                statusBar
                micArea
            } else {
                numberPadContent
            }
            editingRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: keyboardHeight)
        .background(Color(uiColor: .systemGroupedBackground))
        .onChange(of: model.isRecording) { _, isRecording in
            // Keep the user on the voice page while a hold-to-record gesture is active.
            if isRecording {
                page = .voice
            }
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.statusText)
                .font(.caption)
                .lineLimit(1)
            if model.isRecording {
                Text(formatTime(model.elapsedTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !model.polishEnabled {
                Text("润色关")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.toggleChineseScript() }
            } label: {
                Text(model.chineseScript.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.15))
                    )
                    .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected || model.isRecording)
            .opacity((!model.isConnected || model.isRecording) ? 0.45 : 1)
            .accessibilityLabel("中文脚本：\(model.chineseScript.shortLabel)")
            if !model.isConnected {
                Button {
                    onActivateSession()
                } label: {
                    Label("启动会话", systemImage: "mic.badge.plus")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            if model.canRetry {
                Button("重试") {
                    Task { await model.retryTranscription() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            if model.polishEnabled,
               model.polishMode == .askLLM,
               model.askFollowUpAvailable,
               !model.isRecording {
                Button(model.askFollowUpArmed ? "追问中" : "追问") {
                    Task { await model.armAskFollowUp() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!model.isConnected || model.askFollowUpArmed)
                if model.askFollowUpAvailable {
                    Button("新问答") {
                        Task { await model.clearAskConversation() }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .disabled(!model.isConnected || model.isRecording)
                }
            }
        }
        .frame(minHeight: 28)
    }

    // MARK: - Mic (BiBi-like hold / swipe)

    private var micArea: some View {
        VStack(spacing: 8) {
            if model.isRecording {
                HStack(spacing: 3) {
                    ForEach(0..<20, id: \.self) { index in
                        Capsule()
                            .fill(Color.red.opacity(0.8))
                            .frame(width: 3, height: barHeight(index))
                    }
                }
                .frame(height: 28)
                .animation(.easeInOut(duration: 0.12), value: model.elapsedTime)
            }

            HStack(alignment: .center, spacing: 10) {
                Text(model.isRecording ? "← 取消" : " ")
                    .font(.caption)
                    .foregroundStyle(dragX < cancelThreshold / 2 ? Color.red : Color.secondary)
                    .frame(width: 44, alignment: .leading)
                    .opacity(model.isRecording ? 1 : 0)

                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(micFill)
                            .frame(width: 68, height: 68)
                            .shadow(color: micFill.opacity(0.35), radius: model.isRecording ? 10 : 0)
                        Image(systemName: model.isProcessing ? "waveform" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                        if model.isProcessing && !model.isRecording {
                            ProgressView().tint(.white)
                        }

                    }
                    .scaleEffect(model.isRecording ? 1.08 : 1.0)
                    .offset(x: model.isRecording ? min(0, dragX) : 0)
                    .gesture(micGesture)
                    .opacity(!model.isConnected && !model.isRecording ? 0.45 : 1)
                    .accessibilityLabel(model.isRecording ? "正在录音" : "按住说话")

                    Text(model.isRecording ? "松手识别" : "按住说话")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                modeGrid
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 4)
    }

    private var micGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !pressed && !model.isRecording {
                    pressed = true
                    model.noteHoldBegan()
                    Task { await model.onPressDown() }
                }
                if pressed || model.isRecording {
                    dragX = value.translation.width
                }
            }
            .onEnded { value in
                let wasPressed = pressed
                pressed = false
                dragX = 0
                guard wasPressed else { return }
                if value.translation.width < cancelThreshold {
                    Task { await model.onSwipeCancel() }
                } else {
                    Task {
                        if let text = await model.onPressUp(), !text.isEmpty {
                            onInsert(text)
                        }
                    }
                }
            }
    }

    private var micFill: Color {
        if model.isProcessing && !model.isRecording { return .blue }
        if model.isRecording { return .red }
        if model.isConnected { return .accentColor }
        return .gray
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let phase = abs(sin(model.elapsedTime * 8 + Double(index)))
        return 6 + CGFloat(phase) * 20
    }

    // MARK: - Mode grid (2×2 mutual exclusive)

    private var modeGrid: some View {
        let columns = [
            GridItem(.flexible(minimum: 52), spacing: 6),
            GridItem(.flexible(minimum: 52), spacing: 6)
        ]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(PolishMode.gridOrder, id: \.self) { mode in
                modeCell(mode)
            }
        }
        .frame(maxWidth: 156)
        .disabled(!model.isConnected || model.isRecording)
        .opacity((!model.isConnected || model.isRecording) ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("处理模式")
    }

    private func modeCell(_ mode: PolishMode) -> some View {
        let selected = model.polishEnabled && model.polishMode == mode
        return Button {
            Task { await model.selectPolishMode(mode) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: mode.symbolName)
                    .font(.caption.weight(.semibold))
                Text(mode.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.orange.opacity(0.22) : Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.orange.opacity(0.75) : Color.clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Color.orange : Color.primary.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "再次点击关闭润色" : "选择此模式")
    }

    // MARK: - Number page

    private var numberPadContent: some View {
        VStack(spacing: 8) {
            symbolRow
            numberGrid
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbolRow: some View {
        HStack(spacing: 5) {
            ForEach(Self.quickSymbols, id: \.character) { symbol in
                characterKey(
                    symbol.character,
                    accessibilityLabel: symbol.accessibilityLabel,
                    style: .symbol
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("常用符号")
    }

    private var numberGrid: some View {
        VStack(spacing: 6) {
            ForEach(Array(Self.numberPadRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.character) { key in
                        characterKey(
                            key.character,
                            accessibilityLabel: key.accessibilityLabel,
                            style: .number
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("数字键盘")
    }

    // MARK: - Editing row

    private var editingRow: some View {
        HStack(spacing: 6) {
            pageToggleButton
                .frame(width: 56)

            characterKey("空格", accessibilityLabel: "空格", style: .space) {
                requestInsertion(" ")
            }
            .frame(maxWidth: .infinity)

            continuousDeleteButton
                .frame(width: 48)

            characterKey("换行", accessibilityLabel: "换行", style: .returnKey) {
                requestAction(onReturn)
            }
                .frame(width: 64)
        }
    }

    private var pageToggleButton: some View {
        let canSwitch = !model.isRecording
        return Button {
            guard canSwitch else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                page = page == .voice ? .numbers : .voice
            }
        } label: {
            Group {
                if page == .voice {
                    Text("123")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                } else {
                    Image(systemName: "mic.fill")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
            )
        }
        .buttonStyle(KeyboardPressButtonStyle())
        .disabled(!canSwitch)
        .opacity(canSwitch ? 1 : 0.45)
        .accessibilityLabel(page == .voice ? "切换到数字键盘" : "切换到语音键盘")
        .accessibilityHint(canSwitch ? "切换输入页面" : "录音时不可切换")
    }

    private var continuousDeleteButton: some View {
        ContinuousDeleteKey { requestAction(onDelete) }
    }

    // MARK: - Shared key chrome

    private func characterKey(
        _ title: String,
        accessibilityLabel: String,
        style: KeyVisualStyle,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            if let action {
                action()
            } else {
                requestInsertion(title)
            }
        } label: {
            Text(title)
                .font(style.font)
                .frame(maxWidth: .infinity, minHeight: style.minHeight)
                .foregroundStyle(style.foreground)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(style.background)
                        .shadow(color: Color.black.opacity(0.06), radius: 0.5, y: 0.5)
                )
        }
        .buttonStyle(KeyboardPressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func requestInsertion(_ text: String) {
        requestAction { onInsert(text) }
    }

    private func requestAction(_ action: @escaping () -> Void) {
        action()
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch model.currentState {
        case .inactive: .gray
        case .ready: .green
        case .recording: .red
        case .transcribing: .blue
        case .polishing: .orange
        case .error: .red
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Supporting types

private enum KeyboardPage {
    case voice
    case numbers
}

private enum KeyVisualStyle {
    case number
    case symbol
    case space
    case returnKey

    var minHeight: CGFloat {
        switch self {
        case .number: 42
        case .symbol: 34
        case .space, .returnKey: 40
        }
    }

    var font: Font {
        switch self {
        case .number:
            return .title3.weight(.medium).monospacedDigit()
        case .symbol:
            return .subheadline.weight(.medium)
        case .space, .returnKey:
            return .subheadline.weight(.semibold)
        }
    }

    var foreground: Color {
        switch self {
        case .returnKey:
            return .white
        default:
            return .primary
        }
    }

    var background: Color {
        switch self {
        case .returnKey:
            return Color.accentColor
        case .number:
            return Color(uiColor: .secondarySystemGroupedBackground)
        case .symbol, .space:
            return Color(uiColor: .secondarySystemFill)
        }
    }
}

/// Soft press feedback used by character and control keys.
private struct KeyboardPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Long-press friendly delete control.
///
/// Uses a transparent UIControl touch layer so drag-exit / cancellation are reliable,
/// and delegates repeat timing to `DeleteRepeatController`.
private struct ContinuousDeleteKey: View {
    let onDelete: () -> Void

    @State private var isPressed = false
    @State private var controller: DeleteRepeatController?

    var body: some View {
        ZStack {
            Image(systemName: "delete.backward")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                )
                .scaleEffect(isPressed ? 0.96 : 1)
                .opacity(isPressed ? 0.88 : 1)
                .animation(.easeOut(duration: 0.08), value: isPressed)

            DeleteKeyTouchControl(
                onTouchDown: handleTouchDown,
                onTouchEnd: handleTouchEnd
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onDisappear {
            stopRepeating()
        }
        .accessibilityLabel("删除")
        .accessibilityHint("轻点删除一个字符，长按连续删除")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            // VoiceOver keeps single-delete semantics; no continuous repeat.
            onDelete()
        }
    }

    private func activeController() -> DeleteRepeatController {
        if let controller {
            return controller
        }
        let created = DeleteRepeatController(onDelete: onDelete)
        controller = created
        return created
    }

    private func handleTouchDown() {
        isPressed = true
        // One light impact on the initial press only; repeat ticks stay silent.
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.prepare()
        haptic.impactOccurred(intensity: 0.7)
        activeController().pressBegan()
    }

    private func handleTouchEnd() {
        stopRepeating()
    }

    private func stopRepeating() {
        isPressed = false
        controller?.cancel()
    }
}

/// Transparent UIKit control that surfaces the keyboard-grade touch events we need
/// for continuous delete: down, drag-exit, up, and system cancellation.
private struct DeleteKeyTouchControl: UIViewRepresentable {
    var onTouchDown: () -> Void
    var onTouchEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchDown: onTouchDown, onTouchEnd: onTouchEnd)
    }

    func makeUIView(context: Context) -> UIControl {
        let control = UIControl()
        control.backgroundColor = .clear
        control.isAccessibilityElement = false

        let coordinator = context.coordinator
        control.addTarget(coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        control.addTarget(coordinator, action: #selector(Coordinator.touchUpInside), for: .touchUpInside)
        control.addTarget(coordinator, action: #selector(Coordinator.touchUpOutside), for: .touchUpOutside)
        control.addTarget(coordinator, action: #selector(Coordinator.touchDragExit), for: .touchDragExit)
        control.addTarget(coordinator, action: #selector(Coordinator.touchCancel), for: .touchCancel)
        return control
    }

    func updateUIView(_ uiView: UIControl, context: Context) {
        context.coordinator.onTouchDown = onTouchDown
        context.coordinator.onTouchEnd = onTouchEnd
    }

    final class Coordinator: NSObject {
        var onTouchDown: () -> Void
        var onTouchEnd: () -> Void
        private var isTracking = false

        init(onTouchDown: @escaping () -> Void, onTouchEnd: @escaping () -> Void) {
            self.onTouchDown = onTouchDown
            self.onTouchEnd = onTouchEnd
        }

        @objc func touchDown() {
            guard !isTracking else { return }
            isTracking = true
            onTouchDown()
        }

        @objc func touchUpInside() {
            endTracking()
        }

        @objc func touchUpOutside() {
            endTracking()
        }

        @objc func touchDragExit() {
            // Leaving the key cancels the current press session permanently.
            endTracking()
        }

        @objc func touchCancel() {
            endTracking()
        }

        private func endTracking() {
            guard isTracking else { return }
            isTracking = false
            onTouchEnd()
        }
    }
}
