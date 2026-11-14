@MainActor public final class UIPasteboard {
    public static let general = UIPasteboard()
    private var storedString: String?
    public var stringReadCount = 0
    public var simulatedTypes: [String] = []
    public var string: String? {
        get { stringReadCount += 1; return storedString }
        set { storedString = newValue }
    }
    public var hasStrings: Bool { storedString != nil }
    public func contains(pasteboardTypes: [String]) -> Bool {
        pasteboardTypes.contains { simulatedTypes.contains($0) }
    }
}
