import Foundation
import UIKit
import Darwin
import os

/// Best-effort helpers for capturing and reopening the previously active app.
/// Personal / sideloaded use only; relies on private SpringBoard / LaunchServices APIs.
enum AppSwitcher {
    private static let logger = Logger(subsystem: "com.voicepolish.app", category: "AppSwitcher")

    private static let springBoardBundleIDs: Set<String> = [
        "com.apple.springboard",
        "com.apple.SpringBoard"
    ]

    private static let shortcutHostBundleIDs: Set<String> = [
        "com.apple.shortcuts",
        "com.apple.shortcuts.runtime",
        "com.apple.AppSSOUIService",
        "com.apple.ControlCenter",
        "com.apple.controlcenter",
        "com.apple.SiriViewService",
        "com.apple.AppIntentsUIService"
    ]

    private static let knownURLSchemes: [String: String] = [
        "com.tencent.xin": "weixin://",
        "com.apple.mobilenotes": "mobilenotes://"
    ]

    static var ownBundleID: String {
        Bundle.main.bundleIdentifier ?? "com.voicepolish.app"
    }

    /// Capture the current frontmost app, excluding ourselves / SpringBoard / Shortcuts host.
    static func captureReturnTarget() -> String? {
        sanitize(frontmostBundleID())
    }

    /// Control Center is still frontmost when its shortcut begins. Wait for it to
    /// collapse and sample the underlying app before bringing our own app forward.
    @MainActor
    static func waitForReturnTarget(timeout: TimeInterval = 1.0) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let raw = frontmostBundleID()
            if let target = sanitize(raw) {
                logger.notice("Captured return target: \(target, privacy: .public)")
                return target
            }
            if let raw {
                logger.debug("Ignoring foreground service: \(raw, privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        } while Date() < deadline

        logger.error("No return target found after Control Center dismissal")
        return nil
    }

    static func sanitize(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if bundleID == ownBundleID { return nil }
        if springBoardBundleIDs.contains(bundleID) { return nil }
        if shortcutHostBundleIDs.contains(bundleID) { return nil }
        return bundleID
    }

    static func frontmostBundleID() -> String? {
        if let fromSBS = sbsFrontmostBundleID(), !fromSBS.isEmpty {
            return fromSBS
        }
        if let fromUIApp = uiAppFrontmostBundleID(), !fromUIApp.isEmpty {
            return fromUIApp
        }
        return nil
    }

    @discardableResult
    static func open(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let defaultSel = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: defaultSel),
              let workspace = workspaceClass.perform(defaultSel)?.takeUnretainedValue() as? NSObject
        else {
            return false
        }

        let openSel = NSSelectorFromString("openApplicationWithBundleID:")
        if workspace.responds(to: openSel) {
            _ = workspace.perform(openSel, with: bundleID)
            return true
        }

        // Older spelling used by some iOS builds.
        let altSel = NSSelectorFromString("openApplicationWithBundleIdentifier:")
        if workspace.responds(to: altSel) {
            _ = workspace.perform(altSel, with: bundleID)
            return true
        }
        return false
    }

    /// Public URL opening is more reliable than LaunchServices for the two main
    /// keyboard hosts. The private bundle-ID path remains the generic fallback.
    @MainActor
    static func openKnownURL(bundleID: String) async -> Bool {
        guard let scheme = knownURLSchemes[bundleID], let url = URL(string: scheme) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { opened in
                logger.notice("URL return to \(bundleID, privacy: .public): \(opened)")
                continuation.resume(returning: opened)
            }
        }
    }

    static func isFrontmost(bundleID: String) -> Bool {
        frontmostBundleID() == bundleID
    }

    /// Soft suspend — often lands on Home when launched via Shortcuts, so prefer `open(bundleID:)`.
    @MainActor
    static func suspendApplication() {
        let app = UIApplication.shared
        let selector = NSSelectorFromString("suspend")
        if app.responds(to: selector) {
            app.perform(selector)
        }
        UIControl().sendAction(selector, to: app, for: nil)
    }

    // MARK: - Private probes

    private static func sbsFrontmostBundleID() -> String? {
        let path = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        typealias CopyFrontmostFn = @convention(c) () -> Unmanaged<CFString>?
        guard let symbol = dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier") else {
            return nil
        }
        let fn = unsafeBitCast(symbol, to: CopyFrontmostFn.self)
        guard let unmanaged = fn() else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    private static func uiAppFrontmostBundleID() -> String? {
        let app = UIApplication.shared
        let frontSel = NSSelectorFromString("_accessibilityFrontMostApplication")
        guard app.responds(to: frontSel),
              let front = app.perform(frontSel)?.takeUnretainedValue() as? NSObject
        else {
            return nil
        }
        let bidSel = NSSelectorFromString("bundleIdentifier")
        guard front.responds(to: bidSel) else { return nil }
        return front.perform(bidSel)?.takeUnretainedValue() as? String
    }
}
