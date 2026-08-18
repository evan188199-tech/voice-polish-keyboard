import SwiftUI

/// Main-app mirror view of the keyboard's clipboard history.
///
/// Synced one-way from the keyboard via the loopback bridge; deletions here are
/// "hidden" and persist until the keyboard next pushes a snapshot.
struct ClipboardHistoryView: View {
    @ObservedObject var mirror: ClipboardMirrorStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if mirror.entries.isEmpty {
                    ContentUnavailableView(
                        "暂无剪切板历史",
                        systemImage: "list.clipboard",
                        description: Text("键盘唤出时会自动记下当前复制的内容并同步到这里。")
                    )
                } else {
                    List {
                        ForEach(mirror.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.text)
                                    .font(.subheadline)
                                    .lineLimit(6)
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    mirror.hide(id: entry.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("剪切板历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                if !mirror.entries.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("清空", role: .destructive) { mirror.clear() }
                    }
                }
            }
        }
    }
}
