import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var model: KeyboardViewModel
    @ObservedObject var typing: ManualTypingCandidates
    @ObservedObject var pinyin: PinyinComposition
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let captureHostReturn: () -> (@MainActor () -> Void)
    let onActivateSession: () -> Void

    @State private var page: KeyboardPage = .voice
    @State private var dragX: CGFloat = 0
    @State private var pressed = false

    private let cancelThreshold: CGFloat = -60

    @State private var shiftState: ShiftState = .off
    @State private var lastShiftTapAt: Date?
    private let shiftController = ShiftStateController()

    private static let deleteKeyWidth: CGFloat = 52
    private static let deleteKeyHeight: CGFloat = 46

    private static let quickSymbols: [(character: String, accessibilityLabel: String)] = [
        ("@", "at 符号"),
        ("#", "井号"),
        ("$", "美元符号"),
        ("¥", "人民币符号"),
        ("&", "and 符号"),
        ("*", "星号"),
        ("/", "斜杠"),
        ("_", "下划线"),
        (";", "英文分号")
    ]

    private static let numberPadRows: [[(character: String, accessibilityLabel: String)]] = [
        [("1", "1"), ("2", "2"), ("3", "3"), ("+", "加号")],
        [("4", "4"), ("5", "5"), ("6", "6"), ("-", "减号")],
        [("7", "7"), ("8", "8"), ("9", "9"), ("=", "等号")],
        [(".", "小数点"), ("0", "0"), (",", "逗号")]
    ]

    private static let qwertyRowTop = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    private static let qwertyRowHome = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    private static let qwertyRowBottom = ["z", "x", "c", "v", "b", "n", "m"]

    var body: some View {
        VStack(spacing: 4) {
            if page == .voice {
                voiceContent
            } else if page == .abc {
                abcContent
            } else if page == .pinyin {
                PinyinKeyboard(composition: pinyin, insert: requestInsertion, delete: onDelete)
            } else if page == .numbers {
                numberPadContent
            } else {
                clipboardContent
            }
            editingRow
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .frame(height: KeyboardLayout.contentHeight)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear { typing.setActive(page == .abc) }
        .onChange(of: model.isRecording) { _, isRecording in
            // Keep the user on the voice page while a hold-to-record gesture is active.
            if isRecording {
                page = .voice
            }
        }
        .onChange(of: page) { _, newPage in
            typing.setActive(newPage == .abc)
            if newPage != .pinyin { pinyin.clear() }
            // Don't let a stray Shift state persist after leaving the ABC page.
            if newPage != .abc {
                shiftState = .off
            }
        }
    }

    // MARK: - Voice page

    private var voiceContent: some View {
        VStack(spacing: 4) {
            voiceToolbar
            ZStack(alignment: .bottomTrailing) {
                holdZone
                continuousDeleteButton
                    .frame(width: Self.deleteKeyWidth, height: Self.deleteKeyHeight)
                    .disabled(!model.isConnected || model.isRecording)
                    .opacity(model.isRecording ? 0.35 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var voiceToolbar: some View {
        HStack(spacing: 4) {
            voiceStatusRow
                .frame(maxWidth: .infinity)
            modeChips
                .frame(width: 180, height: 32)
        }
        .frame(height: 32)
    }

    private var voiceStatusRow: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if model.isRecording {
                    Text(formatTime(model.elapsedTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !model.polishEnabled {
                    Text("润色关")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)

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
                    Label {
                        Text("启动会话")
                    } icon: {
                        Image(systemName: "mic.badge.plus")
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 22)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .accessibilityLabel("启动会话")
            }
            secondaryActions
        }
        .frame(height: 32)
    }

    private var secondaryActions: some View {
        ViewThatFits(in: .horizontal) {
            directSecondaryActions
            compactSecondaryActions
        }
    }

    @ViewBuilder
    private var directSecondaryActions: some View {
        if let text = model.lastDeliveredText, !text.isEmpty, !model.isRecording {
            Button {
                onInsert(text)
                model.copyLastDeliveredText()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 22, height: 22)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("重新插入最近结果，并复制到剪切板")
        }
        if model.canRetry {
            Button {
                Task { await model.retryTranscription() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("重试")
        }
        if model.polishEnabled,
           model.polishMode == .askLLM,
           model.askFollowUpAvailable,
           !model.isRecording {
            Button {
                Task { await model.armAskFollowUp() }
            } label: {
                Image(systemName: model.askFollowUpArmed ? "hourglass" : "arrowshape.turn.up.left")
                    .frame(width: 22, height: 22)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(!model.isConnected || model.askFollowUpArmed)
            .accessibilityLabel(model.askFollowUpArmed ? "追问中" : "追问")
            if model.askFollowUpAvailable {
                Button {
                    Task { await model.clearAskConversation() }
                } label: {
                    Image(systemName: "plus.bubble")
                        .frame(width: 22, height: 22)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!model.isConnected || model.isRecording)
                .accessibilityLabel("新问答")
            }
        }
    }

    @ViewBuilder
    private var compactSecondaryActions: some View {
        if model.canRetry || hasAskActions {
            Menu {
                secondaryMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 22)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.14))
                    )
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("更多操作")
        }
    }

    @ViewBuilder
    private var secondaryMenuItems: some View {
        if model.canRetry {
            Button("重试") {
                Task { await model.retryTranscription() }
            }
        }
        if hasAskActions {
            Button(model.askFollowUpArmed ? "追问中" : "追问") {
                Task { await model.armAskFollowUp() }
            }
            .disabled(!model.isConnected || model.askFollowUpArmed)
            Button("新问答") {
                Task { await model.clearAskConversation() }
            }
            .disabled(!model.isConnected || model.isRecording)
        }
    }

    private var hasAskActions: Bool {
        model.polishEnabled
            && model.polishMode == .askLLM
            && model.askFollowUpAvailable
            && !model.isRecording
    }

    // MARK: - Hold-to-talk (BiBi-like hold / swipe)

    private var holdZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(holdFill)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    model.isRecording ? Color.red.opacity(0.35) : Color.primary.opacity(0.05),
                    lineWidth: 1
                )

            HStack {
                Text("← 取消")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dragX < cancelThreshold / 2 ? Color.red : Color.secondary)
                    .frame(width: 48, alignment: .leading)
                    .opacity(model.isRecording ? 1 : 0)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)

            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(holdIconFill)
                            .frame(width: 34, height: 34)
                        Image(systemName: model.isProcessing ? "waveform" : "mic.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: model.isRecording ? min(0, dragX) * 0.12 : 0)

                    Text(holdLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.isRecording ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if model.isProcessing && !model.isRecording {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if model.isRecording {
                    HStack(spacing: 3) {
                        ForEach(0..<20, id: \.self) { index in
                            Capsule()
                                .fill(Color.red.opacity(0.8))
                                .frame(width: 3, height: barHeight(index))
                        }
                    }
                    .frame(height: 24)
                    .animation(.easeInOut(duration: 0.12), value: model.elapsedTime)
                }
            }
            .padding(.horizontal, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .gesture(micGesture)
        .opacity(!model.isConnected && !model.isRecording ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.15), value: model.isRecording)
        .accessibilityLabel(model.isRecording ? "正在录音" : "按住说话")
        .accessibilityHint(model.isRecording ? "左滑取消，松手识别" : "按住开始说话")
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

    private var holdLabel: String {
        if model.isRecording { return "松手识别" }
        if model.isProcessing { return "处理中…" }
        return "按住说话"
    }

    private var holdFill: Color {
        if model.isRecording { return Color.red.opacity(0.16) }
        if model.isProcessing { return Color.blue.opacity(0.10) }
        return Color(uiColor: .secondarySystemFill).opacity(model.isConnected ? 0.68 : 0.45)
    }

    private var holdIconFill: Color {
        if model.isProcessing && !model.isRecording { return .blue }
        if model.isRecording { return .red }
        if model.isConnected { return .accentColor }
        return .gray
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let phase = abs(sin(model.elapsedTime * 8 + Double(index)))
        return 6 + CGFloat(phase) * 20
    }

    // MARK: - Mode chips

    private var modeChips: some View {
        return HStack(spacing: 4) {
            ForEach(PolishMode.gridOrder, id: \.self) { mode in
                modeCell(mode)
            }
        }
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
            HStack(spacing: 3) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.orange.opacity(0.20) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.orange.opacity(0.70) : Color.clear, lineWidth: 1.2)
            )
            .foregroundStyle(selected ? Color.orange : Color.primary.opacity(0.75))
        }
        .buttonStyle(KeyboardPressButtonStyle())
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "再次点击关闭润色" : "选择此模式")
    }

    // MARK: - ABC (QWERTY) page

    private var abcContent: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                ForEach(typing.choices) { choice in
                    Button(choice.word) { typing.apply(choice) }
                        .lineLimit(1).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("typing.choice." + choice.word)
                }
                if typing.canUndo {
                    Button { typing.undoLast() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("撤销英文候选").accessibilityIdentifier("typing.undo")
                }
                Spacer(minLength: 0)
                Menu {
                    Button(typing.enabled ? "关闭英文建议" : "开启英文建议") { typing.setEnabled(!typing.enabled) }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("英文输入设置")
            }.frame(minHeight: 30)
            HStack(spacing: 6) {
                ForEach(Self.qwertyRowTop, id: \.self) { letter in
                    letterKey(letter)
                }
            }
            .frame(maxHeight: .infinity)
            // Half-key offset: nudge the home row inward to echo the system keyboard.
            HStack(spacing: 6) {
                ForEach(Self.qwertyRowHome, id: \.self) { letter in
                    letterKey(letter)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                shiftKey()
                ForEach(Self.qwertyRowBottom, id: \.self) { letter in
                    letterKey(letter)
                }
                continuousDeleteButton
                    .frame(width: Self.deleteKeyWidth)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func letterKey(_ letter: String) -> some View {
        let result = shiftController.inserting(character: Character(letter), into: shiftState)
        let display = String(result.output)
        return characterKey(
            display,
            accessibilityLabel: display,
            style: .letter,
            fillsHeight: true,
            action: {
                requestInsertion(display)
                if shiftState == .oneShot {
                    shiftState = .off
                }
            }
        )
    }

    private func shiftKey() -> some View {
        Button {
            let now = Date()
            shiftState = shiftController.shiftTapped(from: shiftState, lastTapAt: lastShiftTapAt, now: now)
            lastShiftTapAt = now
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.prepare()
            haptic.impactOccurred(intensity: 0.7)
        } label: {
            Image(systemName: shiftSymbolName)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .foregroundStyle(shiftState == .locked ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(shiftState == .off ? KeyVisualStyle.special.background : Color.accentColor.opacity(0.18))
                )
        }
        .buttonStyle(KeyboardPressButtonStyle())
        .frame(width: 52)
        .accessibilityLabel(shiftAccessibilityLabel)
        .accessibilityHint("单击大写下一个字母，快速双击锁定大写")
    }

    private var shiftSymbolName: String {
        switch shiftState {
        case .off: "shift"
        case .oneShot: "shift.fill"
        case .locked: "capslock.fill"
        }
    }

    private var shiftAccessibilityLabel: String {
        switch shiftState {
        case .off: "Shift"
        case .oneShot: "Shift，下一个字母大写"
        case .locked: "大写锁定"
        }
    }

    // MARK: - Number page

    private var numberPadContent: some View {
        VStack(spacing: 4) {
            symbolRow
            numberGrid
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
        VStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { rowIndex in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { colIndex in
                        let item = Self.numberPadRows[rowIndex][colIndex]
                        characterKey(
                            item.character,
                            accessibilityLabel: item.accessibilityLabel,
                            style: .number,
                            fillsHeight: true
                        )
                    }
                    let op = Self.numberPadRows[rowIndex][3]
                    characterKey(
                        op.character,
                        accessibilityLabel: op.accessibilityLabel,
                        style: .symbol,
                        fillsHeight: true
                    )
                    .frame(width: Self.deleteKeyWidth)
                }
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { colIndex in
                    let item = Self.numberPadRows[3][colIndex]
                    characterKey(
                        item.character,
                        accessibilityLabel: item.accessibilityLabel,
                        style: .number,
                        fillsHeight: true
                    )
                }
                continuousDeleteButton
                    .frame(width: Self.deleteKeyWidth)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("数字键盘")
    }

    // MARK: - Editing row

    private var returnLabel: String {
        if page == .pinyin && !pinyin.code.isEmpty { return "选词" }
        return model.hostReturnIsSend ? "发送" : "换行"
    }

    private var editingRow: some View {
        let label = returnLabel
        let scopedReturn = captureHostReturn()
        return HStack(spacing: 6) {
            pageToggleButtons
                .frame(width: 175)

            characterKey("空格", accessibilityLabel: "空格", style: .space) {
                if !choosePinyinIfComposing() { requestInsertion(" ") }
            }
            .frame(maxWidth: .infinity)

            characterKey(label, accessibilityLabel: label, style: .returnKey) {
                guard returnLabel == label else { return }
                if choosePinyinIfComposing() { return }
                scopedReturn()
            }
            .frame(width: 64)
        }
        .frame(height: 40)
    }

    private var pageToggleButtons: some View {
        return HStack(spacing: 4) {
            pageButton(.pinyin, label: "拼音", voiceLabel: "拼音键盘", icon: nil)
            pageButton(.abc, label: "ABC", voiceLabel: "英文键盘", icon: nil)
            pageButton(.numbers, label: "123", voiceLabel: "数字键盘", icon: nil)
            pageButton(.clipboard, label: nil, voiceLabel: "剪切板", icon: "list.clipboard")
        }
    }

    private func pageButton(_ target: KeyboardPage, label: String?, voiceLabel: String, icon: String?) -> some View {
        let canSwitch = !model.isRecording
        let isSelected = page == target
        return Button {
            guard canSwitch else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                page = page == target ? .voice : target
            }
        } label: {
            Group {
                if isSelected {
                    Image(systemName: "mic.fill").font(.body.weight(.semibold))
                } else if let icon {
                    Image(systemName: icon).font(.body.weight(.semibold))
                } else if let label {
                    Text(label).font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.orange.opacity(0.22) : Color(uiColor: .secondarySystemFill))
            )
        }
        .buttonStyle(KeyboardPressButtonStyle())
        .disabled(!canSwitch)
        .opacity(canSwitch ? 1 : 0.45)
        .accessibilityLabel(isSelected ? "回到语音键盘" : "切换到\(voiceLabel)")
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
        fillsHeight: Bool = false,
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
                .frame(
                    maxWidth: .infinity,
                    minHeight: style.minHeight,
                    maxHeight: fillsHeight ? .infinity : nil
                )
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

    private func choosePinyinIfComposing() -> Bool {
        guard page == .pinyin, !pinyin.code.isEmpty else { return false }
        if let first = pinyin.visibleChoices.first { pinyin.accept(first, insert: requestInsertion) }
        return true
    }

    private func requestInsertion(_ text: String) {
        requestAction { onInsert(text) }
    }

    private func requestAction(_ action: @escaping () -> Void) {
        action()
    }

    // MARK: - Helpers

    // MARK: - Clipboard page

    private var clipboardContent: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 4) {
                HStack {
                    Text("剪切板历史")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if !model.clipboardEntries.isEmpty {
                        Button("清空", role: .destructive) {
                            model.clearClipboard()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .disabled(model.isRecording)
                    }
                }
                .padding(.horizontal, 2)

                if model.clipboardEntries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.clipboard")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("暂无剪切板记录")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("复制文字后唤出键盘，会自动出现在这里")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.clipboardEntries) { entry in
                                clipboardRow(entry)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, Self.deleteKeyHeight + 6)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            continuousDeleteButton
                .frame(width: Self.deleteKeyWidth, height: Self.deleteKeyHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clipboardRow(_ entry: ClipboardEntry) -> some View {
        Button {
            requestInsertion(entry.text)
            withAnimation(.easeInOut(duration: 0.18)) { page = .voice }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.text)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(relativeTime(entry.createdAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除", role: .destructive) {
                model.deleteClipboardEntry(id: entry.id)
            }
        }
        .accessibilityLabel("插入剪切板内容：\(entry.text.prefix(40))")
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86_400))天前"
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

// MARK: - Supporting types

enum KeyboardPage {
    case voice
    case abc
    case pinyin
    case numbers
    case clipboard

}

enum KeyboardLayout {
    /// The extension-owned content height. iOS supplies the separate globe/microphone bar.
    static let contentHeight: CGFloat = 250
}

private enum KeyVisualStyle {
    case number
    case symbol
    case space
    case returnKey
    case letter
    case special

    var minHeight: CGFloat {
        switch self {
        case .number: 37
        case .symbol: 32
        case .space, .returnKey: 40
        case .letter, .special: 44
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
        case .letter:
            return .title3.weight(.medium)
        case .special:
            return .body.weight(.medium)
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
        case .number, .letter:
            return Color(uiColor: .secondarySystemGroupedBackground)
        case .symbol, .space, .special:
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
