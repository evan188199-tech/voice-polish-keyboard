import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var model: KeyboardViewModel
    @ObservedObject var translation: TranslationViewModel
    @ObservedObject var privateReferences: PrivateReferenceSearchModel
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onReturn: () -> Void
    let onActivateSession: () -> Void
    let onNextKeyboard: () -> Void

    @State private var page: KeyboardPage = .voice
    @State private var translationTracking = false
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
        ("_", "下划线")
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
        .simultaneousGesture(pageSwipe, including: model.canSwitchPage && !translationTracking ? .all : .none)
        .onChange(of: model.appearance) { _, _ in page = .voice }
        .onChange(of: model.isConnected) { _, connected in if !connected { privateReferences.close() } }
        .onChange(of: model.isRecording) { _, isRecording in
            // Keep the user on the voice page while a hold-to-record gesture is active.
            if isRecording {
                page = .voice
            }
        }
        .onChange(of: page) { _, newPage in
            // Don't let a stray Shift state persist after leaving the ABC page.
            if newPage != .abc {
                shiftState = .off
            }
        }
    }

    // MARK: - Voice page

    private var voiceContent: some View {
        VStack(spacing: 0) {
            voiceToolbar
            Spacer(minLength: 4)
            if let review = model.correctionReview, let reviewID = model.correctionReviewID, model.canSwitchPage {
                correctionReviewContent(review, reviewID: reviewID)
            } else if privateReferences.isOpen && model.canSwitchPage {
                privateReferenceContent
            } else if translation.showPreview && model.canSwitchPage {
                TranslationPreviewView(model: translation, onEditSource: { translation.isEditingSource = true; page = .abc },
                    onPasteSource: { if let value = UIPasteboard.general.string { translation.appendSource(value) } },
                    onClose: { translation.showPreview = false; translation.isEditingSource = false })
            } else if let review = model.placeReview, model.canSwitchPage {
                placeReviewContent(review)
            } else {
            HStack(spacing: 20) {
                // Balanced space keeps the microphone centered when Cancel appears.
                Color.clear.frame(width: 48, height: 44)
                VStack(spacing: 7) {
                    microphoneButton
                    Text(microphoneHint)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("voice.captureHint")
                }
                .frame(maxWidth: .infinity)
                Button {
                    Task { await model.cancelRecording() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .secondarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(model.isRecording ? 1 : 0)
                .disabled(!model.isRecording)
                .accessibilityLabel("取消本段录音，保留已提交队列")
                .accessibilityHidden(!model.isRecording)
            }
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                if let queue = model.queueText {
                    if model.isProcessing { ProgressView().controlSize(.mini) }
                    Text(queue)
                } else {
                    Text("左右滑动可打字修正")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 22)
            .accessibilityIdentifier("voice.queueStatus")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var privateReferenceContent: some View {
        VStack(spacing: 4) {
            HStack {
                Text("私人词汇与路线").font(.caption.weight(.semibold))
                Spacer()
                Button("关闭") { privateReferences.close() }.frame(minHeight: 44)
            }
            Text(privateReferences.message).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text(privateReferences.query.isEmpty ? "尚无搜索内容" : privateReferences.query)
                    .font(.caption).lineLimit(1)
                Button("输入搜索") { privateReferences.isEditing = true; page = .abc }.frame(minHeight: 44)
            }
            ScrollView {
                ForEach(privateReferences.results) { item in
                    Button(item.title) {
                        if let text = privateReferences.choose(item.id) { onInsert(text) }
                    }.frame(minHeight: 44)
                }
            }
        }
    }

    private func correctionReviewContent(_ review: CorrectionReviewState, reviewID: UUID) -> some View {
        VStack(spacing: 3) {
            ScrollView {
                Text("收到的文字：\(review.restoreOriginal())").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                if review.phase == .reviewing, let proposal = review.proposal {
                    Text(proposal.hint).font(.caption2)
                    if let draft = proposal.draft { Text("待核对：\(draft)").font(.caption) }
                    HStack {
                        ForEach(proposal.candidates, id: \.self) { candidate in
                            Button(candidate) { model.chooseCorrection(candidate, reviewID: reviewID) }.frame(minHeight: 40)
                        }
                    }
                    Text("手动稿：\(model.correctionManualText)").font(.caption)
                } else if let final = review.finalText { Text("待插入：\(final)").font(.caption) }
            }
            if review.phase == .reviewing {
                HStack {
                    Button("编辑") { if model.correctionReviewID == reviewID { model.startCorrectionEdit(reviewID: reviewID); page = .abc } }
                    Button("采用手动稿") { model.chooseCorrectionManual(model.correctionManualText, reviewID: reviewID) }
                    Button("保留收到的文字") { model.chooseCorrectionOriginal(reviewID: reviewID) }
                    Button("取消") { model.cancelCorrection(reviewID: reviewID) }
                }.font(.caption).frame(minHeight: 44)
            } else if review.phase == .confirmed {
                HStack {
                    Button("返回修改") { model.undoCorrection(reviewID: reviewID) }
                    Button("插入当前输入框") { model.useCorrection(reviewID: reviewID) }
                    Button("取消") { model.cancelCorrection(reviewID: reviewID) }
                }.font(.caption).frame(minHeight: 44)
            }
        }
    }

    private func placeReviewContent(_ review: PlaceReviewDraft) -> some View {
        VStack(spacing: 3) {
            ScrollView {
                Text(review.text).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(review.visibleSuggestions) { suggestion in
                    HStack {
                        Button("\(suggestion.original) → \(suggestion.replacement) \(suggestion.region)") {
                            model.confirmPlace(suggestion.id)
                        }.frame(minHeight: 44)
                        Button("拒绝") { model.rejectPlace(suggestion.id) }.frame(minHeight: 44)
                    }
                }
            }
            HStack {
                Button("撤销") { model.undoPlace() }.disabled(!review.canUndo)
                Button("暂不插入") { model.retainPlaceDraftWithoutInsertion() }
                Button("插入草稿") { model.insertPlaceDraft() }.fontWeight(.semibold)
            }.font(.caption).frame(minHeight: 44)
        }
    }

    private var voiceToolbar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(model.isRecording ? formatTime(model.elapsedTime) : readinessLabel)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(model.statusText)

            Menu {
                Text("离线自动识别：粤语 / 中文 / English")
                Button("香港繁体") { Task { await model.setChineseScript(.traditionalHK) } }
                Button("简体中文") { Task { await model.setChineseScript(.simplified) } }
            } label: {
                Text("粤英 · \(model.chineseScript.shortLabel)")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 74, minHeight: 44)
            }
            .disabled(!model.isConnected || !model.canSwitchPage)
            .accessibilityLabel("识别语言和中文输出字体")

            Menu {
                ForEach(PolishMode.gridOrder, id: \.self) { mode in
                    Button {
                        Task { await model.selectPolishMode(mode) }
                    } label: {
                        Label(mode.displayName, systemImage: model.polishEnabled && model.polishMode == mode ? "checkmark" : mode.symbolName)
                    }
                }
                Button(model.polishEnabled ? "关闭润色" : "开启润色") {
                    Task { await model.togglePolishEnabled() }
                }
                Text("问答仅在明确选择该模式时执行")
            } label: {
                Text(model.polishEnabled ? model.polishMode.shortLabel : "原文")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!model.isConnected || !model.canSwitchPage)
            .accessibilityLabel("处理模式：\(model.polishEnabled ? model.polishMode.displayName : "原文")")

            Menu {
                if model.heldResult != nil {
                    Button("将保留结果插入当前输入框") { model.insertHeldResult() }
                } else if let text = model.lastDeliveredText, !text.isEmpty {
                    Button("插入最近结果（可能重复）") { onInsert(text) }
                    Button("复制最近结果") { model.copyLastDeliveredText() }
                }
                if model.canRetry {
                    Button("重新连接，不重交录音") { Task { await model.retryTranscription() } }
                }
                if model.askFollowUpAvailable {
                    Button(model.askFollowUpArmed ? "已准备追问" : "追问") {
                        Task { await model.armAskFollowUp() }
                    }.disabled(model.askFollowUpArmed)
                    Button("新问答") { Task { await model.clearAskConversation() } }
                }
                Button("私人词汇与路线（未连接）") { translation.showPreview = false; translation.isEditingSource = false; privateReferences.open() }
                Button("翻译与原文恢复") { privateReferences.close(); translation.showPreview = true }
                Button("打开主应用") { onActivateSession() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .disabled(!model.canSwitchPage)
            .accessibilityLabel("更多操作与结果恢复")
        }
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
    }

    private var microphoneButton: some View {
        TranslationSpeakControl(targets: translation.capability.orderedTargets,
            canTranslate: translation.capability.isAvailable && model.isConnected && !model.needsActivation,
            isRecording: model.isRecording, isBusy: model.capture.isTransitioning || model.isConnecting,
            needsActivation: model.needsActivation,
            onTap: {
                if model.needsActivation || !model.isConnected { onActivateSession() }
                else { Task { await model.toggleRecording() } }
            },
            onTranslate: { target in model.startTranslation(target, translation: translation) },
            onTracking: { translationTracking = $0 })
            .accessibilityIdentifier("voice.microphone")
    }

    private var readinessLabel: String {
        if model.isConnecting { return "连接中" }
        if model.needsActivation { return "待激活" }
        if model.capture.isTransitioning { return "请稍候" }
        return "语音就绪"
    }

    private var microphoneHint: String {
        if model.capture.isTransitioning || model.canRetry { return model.statusText }
        if model.isRecording { return "再次点击完成" }
        if model.needsActivation { return "打开主应用准备录音" }
        return "点击说话"
    }

    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !translationTracking, VoiceKeyboardSwipe.shouldSwitch(
                    horizontal: Double(value.translation.width), vertical: Double(value.translation.height),
                    capture: model.capture
                ) else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    page = page == .voice ? .abc : .voice
                }
            }
    }

    // MARK: - ABC (QWERTY) page

    private var abcContent: some View {
        VStack(spacing: 5) {
            if model.correctionEditing { correctionEditingHeader }
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

    private var correctionEditingHeader: some View {
        HStack {
            Text(model.correctionManualText.isEmpty ? "输入完整结果" : model.correctionManualText)
                .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let reviewID = model.correctionReviewID {
                Button("完成") { if model.correctionReviewID == reviewID { model.finishCorrectionEdit(reviewID: reviewID); page = .voice } }
                    .font(.caption.weight(.semibold)).frame(minHeight: 36)
            }
        }.accessibilityLabel("编辑纠字草稿，不会直接输入宿主")
    }

    private var numberPadContent: some View {
        VStack(spacing: 4) {
            if model.correctionEditing { correctionEditingHeader }
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

    private var editingRow: some View {
        HStack(spacing: 6) {
            Button(action: onNextKeyboard) {
                Image(systemName: "globe").font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一个系统键盘")
            if page == .voice {
                pageButton(.abc, label: "ABC", voiceLabel: "英文键盘", icon: nil)
                    .frame(width: 52)
                Spacer(minLength: 0)
                continuousDeleteButton.frame(width: 52, height: 44)
            } else {
                pageToggleButtons.frame(width: 132)
                characterKey("空格", accessibilityLabel: "空格", style: .space) {
                    requestInsertion(" ")
                }
            }
            characterKey("回车", accessibilityLabel: "回车，遵循当前应用行为", style: .returnKey) {
                if model.correctionEditing, let reviewID = model.correctionReviewID { model.finishCorrectionEdit(reviewID: reviewID); page = .voice }
                else if privateReferences.isEditing { privateReferences.isEditing = false; page = .voice }
                else if translation.isEditingSource { requestInsertion("\n") } else { requestAction(onReturn) }
            }
            .frame(width: 64)
        }
        .frame(height: 44)
    }

    private var pageToggleButtons: some View {
        return HStack(spacing: 4) {
            pageButton(.abc, label: "ABC", voiceLabel: "英文键盘", icon: nil)
            pageButton(.numbers, label: "123", voiceLabel: "数字键盘", icon: nil)
            pageButton(.clipboard, label: nil, voiceLabel: "剪切板", icon: "list.clipboard")
        }
    }

    private func pageButton(_ target: KeyboardPage, label: String?, voiceLabel: String, icon: String?) -> some View {
        let canSwitch = model.canSwitchPage
        let isSelected = page == target
        return Button {
            guard canSwitch else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                page = page == target ? .voice : target
            }
        } label: {
            Group {
                if let icon {
                    Image(systemName: icon).font(.body.weight(.semibold))
                } else if let label {
                    Text(label).font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
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
        ContinuousDeleteKey {
            if model.correctionEditing { model.deleteCorrectionText() }
            else if privateReferences.isEditing { privateReferences.deleteBackward() }
            else if translation.isEditingSource { translation.deleteSourceBackward() }
            else { requestAction(onDelete) }
        }
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

    private func requestInsertion(_ text: String) {
        if model.correctionEditing { model.appendCorrectionText(text) }
        else if privateReferences.isEditing { privateReferences.append(text) }
        else if translation.isEditingSource { translation.appendSource(text) }
        else { requestAction { onInsert(text) } }
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
            .frame(minHeight: 44)
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
    case numbers
    case clipboard

}

enum KeyboardLayout {
    /// The extension-owned content height, including its own public next-keyboard button.
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
        case .space, .returnKey: 44
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
                .frame(maxWidth: .infinity, minHeight: 44)
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
