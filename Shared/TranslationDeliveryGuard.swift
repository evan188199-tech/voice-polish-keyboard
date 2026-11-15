import Foundation

/// Conservative evidence for one insertion attempt; never stores host text.
/// Matching signals do not prove that a host correctly reports every focus change.
struct TranslationDeliveryGuard {
    private struct Binding { let document: UUID; let epoch: UInt64 }
    private var epoch: UInt64 = 0
    private var bindings: [UUID: Binding] = [:]

    mutating func invalidate() { epoch &+= 1; bindings.removeAll() }
    mutating func capture(_ requestID: UUID, document: UUID?, visible: Bool, connected: Bool, continuityVerified: Bool = false) {
        bindings[requestID] = nil
        guard visible, connected, continuityVerified, let document else { return }
        bindings[requestID] = Binding(document: document, epoch: epoch)
    }
    mutating func abandon(_ requestID: UUID) { bindings[requestID] = nil }
    mutating func consume(_ requestID: UUID, document: UUID?, visible: Bool, connected: Bool) -> Bool {
        guard let binding = bindings.removeValue(forKey: requestID), visible, connected,
              let document else { return false }
        return binding.epoch == epoch && binding.document == document
    }
}
