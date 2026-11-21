import Foundation

let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func lookup(_ scheme: PinyinScheme, _ input: String) -> [PinyinCandidate] {
    let url = resources.appendingPathComponent(scheme.resource + ".lex")
    guard let dictionary = PinyinLexicon(url: url) else { fatalError("Missing dictionary: " + url.path) }
    return dictionary.candidates(for: input)
}
for (scheme, input, word): (PinyinScheme, String, String) in [
    (.full, "nihao", "你好"), (.full, "jintiantianqi", "今天天气"), (.full, "xi'an", "西安"),
    (.full, "xingqing", "性情"), (.sogou, "x;q;", "性情"), (.sogou, "m;", "明"),
    (.sogou, "q;", "请"), (.sogou, "id", "窗"), (.sogou, "ol", "爱"),
    (.sogou, "vi", "知"), (.sogou, "ui", "是")
] {
    precondition(lookup(scheme, input).contains(PinyinCandidate(word: word, consumed: input.count)), input)
}
precondition(!lookup(.full, "xi'an").contains(PinyinCandidate(word: "先", consumed: 5)))
precondition(lookup(.full, "nihaoq").contains(PinyinCandidate(word: "你好", consumed: 5)))
precondition(lookup(.full, String(repeating: "a", count: 65)).isEmpty)
print("Offline full and Sogou dictionary lookups passed.")
