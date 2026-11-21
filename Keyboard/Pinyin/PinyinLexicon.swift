import Foundation

enum PinyinScheme: String {
    case full = "全拼"
    case sogou = "搜狗双拼"

    var resource: String { self == .full ? "FullPinyin" : "SogouPinyin" }
}

struct PinyinCandidate: Equatable, Hashable {
    let word: String
    let consumed: Int
}

/// Search an immutable frequency-sorted dictionary without loading the word list into extension memory.
struct PinyinLexicon {
    private let data: Data
    private let count: Int
    private let records: Int

    init?(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 8 else { return nil }
        let count = Self.integer(data, 0)
        let records = 4 + 4 * (count + 1)
        guard count > 0, records <= data.count,
              Self.integer(data, records - 4) == data.count - records else { return nil }
        self.data = data
        self.count = count
        self.records = records
    }

    private static func integer(_ data: Data, _ offset: Int) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
    }

    private func offset(_ row: Int) -> Int { records + Self.integer(data, 4 + row * 4) }

    private func compare(_ row: Int, _ key: ArraySlice<UInt8>, shortcut: Bool) -> Int {
        var i = offset(row)
        if shortcut {
            let marker: UInt8 = 126 // "~" in the compiled table
            if data[i] != marker { return Int(data[i]) - Int(marker) }
            i += 1
        }
        for letter in key {
            let byte = data[i]
            if byte != letter { return Int(byte) - Int(letter) }
            i += 1
        }
        return data[i] == 9 ? 0 : 1
    }

    private struct Match {
        let word: String
        let cost: Int
    }

    private func matches(_ key: ArraySlice<UInt8>, boundaries: Set<Int>, firstOnly: Bool, shortcut: Bool = false) -> [Match] {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, key, shortcut: shortcut) < 0 { low = mid + 1 } else { high = mid }
        }
        var result: [Match] = []
        while low < count && compare(low, key, shortcut: shortcut) == 0 {
            let start = offset(low) + key.count + (shortcut ? 2 : 1)
            let end = offset(low + 1)
            low += 1
            var i = start, boundary = key.startIndex, hit = 0
            while data[i] != 9 {
                boundary += Int(data[i]) - 48
                if boundaries.contains(boundary) { hit += 1 }
                i += 1
            }
            guard hit == boundaries.filter({ $0 > key.startIndex && $0 <= key.endIndex }).count else { continue }
            i += 1
            var cost = 0
            while data[i] != 9 {
                cost = cost * 10 + Int(data[i]) - 48
                i += 1
            }
            result.append(Match(word: String(decoding: data[(i + 1)..<end], as: UTF8.self), cost: cost))
            if firstOnly { break }
        }
        return result
    }

    func candidates(for raw: String) -> [PinyinCandidate] {
        guard !raw.isEmpty, raw.utf8.count <= 64 else { return [] }
        var letters: [UInt8] = [], consumed = [0], boundaries: Set<Int> = []
        for (i, byte) in raw.utf8.enumerated() {
            if byte == 39 {
                boundaries.insert(letters.count)
                consumed[letters.count] = i + 1
            } else {
                letters.append(byte)
                consumed.append(i + 1)
            }
        }
        let n = letters.count
        guard n > 0 else { return [] }
        var best = Array<(word: String, cost: Int)?>(repeating: nil, count: n + 1)
        best[n] = ("", 0)
        var prefixes: [PinyinCandidate] = []
        let hasShortcuts = data[offset(count - 1)] == 126
        for i in (0..<n).reversed() {
            for end in (i + 1...min(n, i + 32)).reversed() where i == 0 || best[end] != nil {
                let matches = matches(letters[i..<end], boundaries: boundaries, firstOnly: i != 0)
                if i == 0 {
                    var choices = matches
                    if hasShortcuts {
                        choices += self.matches(letters[i..<end], boundaries: boundaries, firstOnly: false, shortcut: true)
                    }
                    prefixes += choices.map { PinyinCandidate(word: $0.word, consumed: consumed[end]) }
                }
                if let first = matches.first, let rest = best[end] {
                    let cost = first.cost + rest.cost
                    if cost < (best[i]?.cost ?? Int.max) { best[i] = (first.word + rest.word, cost) }
                }
            }
        }
        if let phrase = best[0] { prefixes.insert(PinyinCandidate(word: phrase.word, consumed: raw.utf8.count), at: 0) }
        var seen = Set<PinyinCandidate>()
        return prefixes.filter { seen.insert($0).inserted }
    }
}
