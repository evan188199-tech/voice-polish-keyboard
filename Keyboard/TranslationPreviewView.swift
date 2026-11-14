import SwiftUI
import UIKit

/// Optional recovery/text workspace. Voice success normally bypasses this view.
/// The keyboard owner supplies explicit editing/paste actions; this view never
/// reads host context or the clipboard in the background.
struct TranslationPreviewView: View {
    @ObservedObject var model: TranslationViewModel
    let onEditSource: () -> Void
    let onPasteSource: () -> Void
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("翻译与原文恢复").font(.caption.weight(.semibold))
                Spacer()
                Button("关闭", action: onClose).frame(minWidth: 44, minHeight: 44)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("原文").font(.caption.weight(.semibold))
                    Text(model.draft.source.isEmpty ? "主动输入、粘贴或选择最近原文" : model.draft.source)
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("输入/编辑", action: onEditSource)
                        Button("粘贴原文", action: onPasteSource)
                        Button("恢复原文") { model.restoreSource() }
                    }.font(.caption).frame(minHeight: 44)
                    Menu {
                        ForEach(model.capability.orderedTargets) { target in
                            Button(target.displayName) { model.chooseTarget(target) }
                                .disabled(!model.capability.supportedTargets.contains(target))
                        }
                    } label: {
                        Label(model.draft.target.displayName, systemImage: "character.bubble")
                            .font(.caption).frame(minHeight: 44)
                    }
                    Toggle("仅预览这次手动翻译", isOn: $model.previewBeforeInsert).font(.caption).disabled(model.draft.isBusy)
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                    Text("服务：\(model.capability.serviceLabel)。只有主动启用后才发送当前文字；不上传音频或整份词典。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let translated = model.draft.translation {
                        Text("译文 → \(model.draft.target.displayName)").font(.caption.weight(.semibold))
                        Text(translated).font(.caption)
                    }
                    if let event = model.lastEvent {
                        Divider()
                        Text("最近原文：\(event.source)").font(.caption)
                        if let text = event.translation { Text("最近译文：\(text)").font(.caption) }
                        if let failure = event.failure { Text(failure.message).font(.caption).foregroundStyle(.orange) }
                        Button("恢复最近原文到编辑区") { model.restoreLastOriginal() }.font(.caption).frame(minHeight: 44)
                    }
                    Text("请核对姓名、地名、否定与语气；自动检查不能证明翻译准确。插入仅为草稿，不会发送。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("取消") { model.cancelDraft() }
                Button("插入原文") { model.insertOriginal() }
                if model.draft.previewCanInsert {
                    Button("插入预览译文") { model.insertPreview() }
                } else {
                    Button(model.previewBeforeInsert ? "生成预览" : "翻译并插入") { model.submitTyped() }
                        .disabled(model.draft.isBusy || !model.capability.isAvailable)
                }
            }.font(.caption).frame(minHeight: 44)
        }
        .accessibilityIdentifier("translation.optionalPreview")
    }
}
