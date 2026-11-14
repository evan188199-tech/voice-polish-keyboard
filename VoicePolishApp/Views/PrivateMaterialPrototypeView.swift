import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PrivateMaterialPrototypeView: View {
    @StateObject private var session = PrivateMaterialSession()
    @State private var importing = false
    @State private var preview: TermImportPreview?
    @State private var selected = Set<UUID>()
    @State private var importAccount = ""
    @State private var importVersion = 0
    @State private var search = ""
    @State private var reviewedImport = false
    @State private var confirmedMaterial: [UUID: MaterialSelection] = [:]
    @State private var draftMaterial: ProductMaterial?
    @State private var draft = ""
    @State private var message: String?
    @State private var copyImage: ProductMaterial?
    @State private var showCopyWarning = false
    @State private var share: SharePayload?

    var body: some View {
        List {
            Section("接入状态") {
                Text(session.status)
                Button("真实账号（尚未接入）") { session.connectProduction() }
                HStack {
                    Button("演示工作区 A") { resetUI(); Task { await session.useDemo("demo-A") } }
                    Button("演示工作区 B") { resetUI(); Task { await session.useDemo("demo-B") } }
                }
                Button("注销 / 撤权并清缓存", role: .destructive) { resetUI(); session.logout() }
                Text(session.keyboardAvailability).font(.caption).foregroundStyle(.secondary)
            }
            Section("本机搜索") {
                TextField("搜索已确认的词汇或演示素材", text: $search)
                Text("仅本机当前会话，未连接真实内容中台或键盘。").font(.caption).foregroundStyle(.secondary)
            }
            Section("本地私人词汇预览") {
                Text("仅导入你明确选择的 JSON 文件。白名单只取 term/kind，其他字段不保存。过滤不等于完成脱敏，请逐项人工核对；本轮只存当前工作区内存，注销即清空，不发布、不上传。")
                    .font(.caption)
                Button("选择本地词汇 JSON") { importAccount = session.account?.id ?? ""; importVersion = session.cacheVersion; importing = true }.disabled(session.account == nil)
                if let preview {
                    Text("保留 \(preview.candidates.count) 项；拒绝 \(preview.rejectedCount) 项；忽略 \(preview.ignoredFieldCount) 个非白名单字段。")
                        .font(.caption)
                    ForEach(preview.candidates) { item in
                        Toggle("\(item.term) [\(item.kind.rawValue)]", isOn: Binding(
                            get: { selected.contains(item.id) },
                            set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                    }
                    Toggle("我已逐项核对，内容只供本机私人搜索", isOn: $reviewedImport)
                    Button("确认选择的词汇") {
                        do {
                            try session.confirmImport(preview, selected: selected, expectedAccount: importAccount, reviewed: reviewedImport)
                            self.preview = nil; selected.removeAll(); reviewedImport = false
                        } catch { message = error.localizedDescription }
                    }.disabled(!reviewedImport || selected.isEmpty)
                }
                ForEach(session.searchTerms(search)) { term in
                    HStack {
                        Text(term.term).font(.caption)
                        Spacer()
                        Button("复制词汇") { copyLocalText(term.term) }
                    }
                }
            }
            Section("虚构素材 · 仅测试权限与分享界面") {
                ForEach(session.searchMaterials(search)) { material in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(material.displayName).font(.headline)
                        Text("\(material.verification.rawValue) / \(material.visibility.rawValue) / v\(material.version)").font(.caption)
                        if let url = material.customerURL { Text("目的地：\(url.absoluteString)").font(.caption).textSelection(.enabled) }
                        Text(material.attribution).font(.caption)
                        if material.hasApprovedImage {
                            Image(uiImage: demoImage()).resizable().scaledToFit().frame(maxHeight: 140)
                                .accessibilityLabel("本项目原创虚构素材图片预览")
                        }
                        Toggle("确认本次仅使用此演示素材", isOn: Binding(
                            get: { confirmedMaterial[material.id] != nil },
                            set: { selected in
                                if selected { confirmedMaterial[material.id] = try? session.select(material) }
                                else { confirmedMaterial[material.id] = nil }
                            }))
                        if let reason = session.rejection(material, selection: confirmedMaterial[material.id], action: .textDraft,
                                                          confirmed: confirmedMaterial[material.id] != nil) {
                            Text("草稿已阻止：\(reason)").font(.caption).foregroundStyle(.orange)
                        }
                        Button("预览文字与链接草稿") {
                            do {
                                draft = try session.draft(material, selection: confirmedMaterial[material.id], confirmed: confirmedMaterial[material.id] != nil)
                                draftMaterial = material
                            }
                            catch { message = error.localizedDescription }
                        }
                        HStack {
                            Button("系统分享示例图") { prepareImage(material, copying: false) }
                            Button("复制示例图…") { copyImage = material; showCopyWarning = true }
                        }
                    }.padding(.vertical, 5)
                }
            }
            if !draft.isEmpty {
                Section("可编辑草稿 · 未发送") {
                    TextEditor(text: $draft).frame(minHeight: 120)
                    HStack {
                        Button("复制草稿到本机") { useDraft(sharing: false) }
                        Button("系统分享草稿") { useDraft(sharing: true) }
                    }
                    Button("撤销/清除草稿") { draft = ""; draftMaterial = nil }
                }
            }
            if let message { Section { Text(message).font(.caption).foregroundStyle(.secondary) } }
        }
        .navigationTitle("私人素材安全原型")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 262_144 else { throw MaterialPrototypeError.invalidImport }
                guard session.account?.id == importAccount, session.cacheVersion == importVersion else { throw MaterialPrototypeError.wrongAccount }
                let candidatePreview = try session.previewImport(Data(contentsOf: url))
                preview = candidatePreview
                selected.removeAll(); reviewedImport = false
            } catch { message = error.localizedDescription }
        }
        .alert("复制会将图片暴露给本机剪贴板", isPresented: $showCopyWarning) {
            Button("取消", role: .cancel) { copyImage = nil }
            Button("复制到本机，60 秒后过期") {
                if let material = copyImage { prepareImage(material, copying: true) }
                copyImage = nil
            }
        } message: {
            Text("复制不是发送。到宿主中自行粘贴并选择收件人；有些应用不接受图片。不会跨设备同步。")
        }
        .sheet(item: $share) { payload in MaterialShareSheet(items: payload.items) }
        .onDisappear { resetUI(); session.logout() }
    }
    private func demoImage() -> UIImage {
        // Original fixed-size placeholder, not a real product image or remote asset.
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            ("虚构示例素材\n本项目原创演示图" as NSString).draw(in: CGRect(x: 48, y: 140, width: 544, height: 160),
                withAttributes: [.font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.white])
        }
    }

    private func resetUI() {
        preview = nil; selected.removeAll(); confirmedMaterial.removeAll()
        reviewedImport = false; draft = ""; draftMaterial = nil; search = ""; share = nil; copyImage = nil; message = nil
        // Clear only the clipboard item this screen created, without reading it.
        if let change = ownedPasteboardChange, UIPasteboard.general.changeCount == change { UIPasteboard.general.items = [] }
        ownedPasteboardChange = nil
    }
    @State private var ownedPasteboardChange: Int?
    private func copyLocalText(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text,
                                        ClipboardHistoryPolicy.transientPrivateType: Data([1])]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        ownedPasteboardChange = UIPasteboard.general.changeCount
        message = "已复制到本机剪贴板，60 秒后过期；不会自动发送。"
    }
    private func useDraft(sharing: Bool) {
        guard let material = draftMaterial,
              session.rejection(material, selection: confirmedMaterial[material.id], action: .textDraft,
                                confirmed: confirmedMaterial[material.id] != nil) == nil,
              !draft.isEmpty else { message = "素材已过期或会话已变化，请重新确认。"; return }
        if sharing { share = SharePayload(items: [draft]) }
        else { copyLocalText(draft) }
    }
    private func prepareImage(_ material: ProductMaterial, copying: Bool) {
        do {
            _ = try session.imageReference(material, selection: confirmedMaterial[material.id],
                                           confirmed: confirmedMaterial[material.id] != nil)
        } catch { message = "操作已阻止：" + error.localizedDescription; return }
        let image = demoImage()
        if copying {
            UIPasteboard.general.setItemProviders([NSItemProvider(object: image)], localOnly: true, expirationDate: Date().addingTimeInterval(60))
            ownedPasteboardChange = UIPasteboard.general.changeCount
            message = "示例图已复制到本机；请自行粘贴并确认。未发送。"
        } else { share = SharePayload(items: [image, material.attribution]) }
    }
}
private struct SharePayload: Identifiable { let id = UUID(); let items: [Any] }
private struct MaterialShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
