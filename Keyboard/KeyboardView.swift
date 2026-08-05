import SwiftUI

struct KeyboardView: View {
    @ObservedObject var model: KeyboardViewModel
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onReturn: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var pressed = false

    private let cancelThreshold: CGFloat = -60

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

    var body: some View {
        VStack(spacing: 8) {
            statusBar
            micArea
            symbolRow
            editingRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 268)
        .background(Color(uiColor: .systemBackground))
        .task { await model.connect() }
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
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.orange.opacity(0.15))
                    )
                    .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected || model.isRecording)
            .opacity((!model.isConnected || model.isRecording) ? 0.45 : 1)
            if !model.isConnected {
                Text("未连接")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if model.canRetry {
                Button("重试") {
                    Task { await model.retryTranscription() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .frame(minHeight: 28)
    }

    // MARK: - Mic (BiBi-like hold / swipe)

    private var micArea: some View {
        VStack(spacing: 8) {
            if model.isRecording {
                // Lightweight animated bars while holding
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
                    .disabled(!model.isConnected)
                    .opacity(!model.isConnected && !model.isRecording ? 0.45 : 1)

                    Text(model.isRecording ? "松手识别" : "按住说话")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                modeGrid
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
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
                // Track drag even before the async start completes so left-swipe cancel works.
                if pressed || model.isRecording {
                    dragX = value.translation.width
                }
            }
            .onEnded { value in
                let wasPressed = pressed
                defer {
                    pressed = false
                    dragX = 0
                }
                // End based on the finger session, not isRecording — start may still be in flight.
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.orange.opacity(0.22) : Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.orange.opacity(0.75) : Color.clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Color.orange : Color.primary.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "再次点击关闭润色" : "选择此模式")
    }

    // MARK: - Symbols & Editing

    private var symbolRow: some View {
        HStack(spacing: 4) {
            ForEach(Self.quickSymbols, id: \.character) { symbol in
                Button {
                    onInsert(symbol.character)
                } label: {
                    Text(symbol.character)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(symbol.accessibilityLabel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("常用符号")
    }

    private var editingRow: some View {
        HStack(spacing: 6) {
            keyButton("空格") { onInsert(" ") }
                .frame(maxWidth: .infinity)
            iconButton("delete.backward", action: onDelete)
            keyButton("换行", action: onReturn)
                .frame(width: 64)
        }
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 44, height: 36)
        }
        .buttonStyle(.bordered)
    }

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
