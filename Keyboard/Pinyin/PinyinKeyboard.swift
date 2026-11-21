import SwiftUI

@MainActor
final class PinyinComposition: ObservableObject {
    @Published private(set) var code = ""
    @Published private(set) var candidates: [PinyinCandidate] = []
    @Published var page = 0
    @Published private(set) var scheme: PinyinScheme
    let pageSize = 4
    private var lexicon: PinyinLexicon?
    private var origin: UUID?
    var currentDocument: () -> UUID? = { nil }

    init() {
        scheme = UserDefaults.standard.string(forKey: "pinyin.scheme").flatMap(PinyinScheme.init) ?? .full
    }

    func choose(_ value: PinyinScheme) {
        guard value != scheme else { return }
        clear()
        scheme = value
        UserDefaults.standard.set(value.rawValue, forKey: "pinyin.scheme")
        lexicon = nil
    }

    func append(_ key: String) {
        if origin != currentDocument() { clear() }
        guard code.count < 64, key != "'" || (!code.isEmpty && !code.hasSuffix("'")) else { return }
        origin = currentDocument()
        code += key
        refresh()
    }

    func accept(_ candidate: PinyinCandidate, insert: (String) -> Void) {
        guard let origin, origin == currentDocument(), candidates.contains(candidate) else { clear(); return }
        code.removeFirst(candidate.consumed)
        refresh()
        insert(candidate.word)
    }

    func backspace() {
        guard !code.isEmpty else { return }
        code.removeLast()
        refresh()
    }

    func clear() {
        code = ""
        candidates = []
        page = 0
        origin = nil
    }

    var visibleChoices: ArraySlice<PinyinCandidate> {
        candidates.dropFirst(page * pageSize).prefix(pageSize)
    }

    private func refresh() {
        page = 0
        if lexicon == nil {
            lexicon = PinyinLexicon(url: Bundle.main.url(forResource: scheme.resource, withExtension: "lex"))
        }
        candidates = code.isEmpty ? [] : (lexicon?.candidates(for: code) ?? [])
    }
}

struct PinyinKeyboard: View {
    @ObservedObject var composition: PinyinComposition
    let insert: (String) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Menu(composition.scheme.rawValue) {
                    ForEach([PinyinScheme.full, .sogou], id: \.self) { scheme in
                        Button(scheme.rawValue) { composition.choose(scheme) }
                    }
                }.accessibilityLabel("拼音方案，" + composition.scheme.rawValue).accessibilityIdentifier("pinyin.scheme")
                Text(composition.code).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("pinyin.code")
                if !composition.code.isEmpty {
                    Button("清除") { composition.clear() }.accessibilityLabel("清除拼音编码")
                }
                Menu("标点") {
                    ForEach(["，", "。", "？", "！", "；", "、"], id: \.self) { mark in
                        Button(mark) { insert(mark) }
                    }
                }.disabled(!composition.code.isEmpty)
            }.font(.footnote).frame(minHeight: 25)
            HStack(spacing: 3) {
                Button { composition.page -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(composition.page == 0).accessibilityLabel("上一页候选")
                ForEach(Array(composition.visibleChoices), id: \.self) { choice in
                    Button(choice.word) { composition.accept(choice, insert: insert) }
                        .lineLimit(1).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("pinyin.choice." + choice.word)
                }
                Spacer(minLength: 0)
                Button { composition.page += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled((composition.page + 1) * composition.pageSize >= composition.candidates.count)
                    .accessibilityLabel("下一页候选")
            }.frame(minHeight: 30)
            row("qwertyuiop")
            row(composition.scheme == .sogou ? "asdfghjkl;" : "asdfghjkl")
            HStack(spacing: 4) {
                key("’", label: "拼音隔音符") { composition.append("'") }
                letters("zxcvbnm")
                key("⌫", label: "退格") {
                    if composition.code.isEmpty { delete() } else { composition.backspace() }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func row(_ keys: String) -> some View {
        HStack(spacing: 4) { letters(keys) }
    }

    private func letters(_ keys: String) -> some View {
        ForEach(keys.map(String.init), id: \.self) { letter in
            key(letter, label: letter == ";" ? "分号，韵母 ing" : letter) { composition.append(letter) }
        }
    }

    private func key(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.title3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 5))
        }.accessibilityLabel(label)
    }
}
