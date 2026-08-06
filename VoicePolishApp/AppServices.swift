import Foundation
import Combine
import UIKit
import os

/// Process-wide services so App Intents and SwiftUI share one coordinator.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()
    private let logger = Logger(subsystem: "com.voicepolish.app", category: "AppServices")

    let coordinator = VoiceSessionCoordinator()
    let settings = AppSettings()

    /// Bundle ID of the app that was frontmost when the shortcut started (e.g. WeChat).
    private var returnTargetBundleID: String?
    private var pendingReturnToPreviousApp = false
    private var returnTask: Task<Void, Never>?

    private init() {}

    /// Capture / remember which app we should reopen after activation.
    func rememberReturnTarget(_ bundleID: String?) {
        // Always reset per invocation. Reusing a prior target makes a failed
        // capture look like a deliberate choice (for example, always WeChat).
        returnTargetBundleID = nil
        if let clean = AppSwitcher.sanitize(bundleID) {
            returnTargetBundleID = clean
            logger.notice("Remembered return target: \(clean, privacy: .public)")
        } else {
            logger.notice("No return target for this invocation")
        }
    }

    /// Scene tracking: when another app becomes frontmost after we leave, remember it.
    func noteForeignFrontmostIfPossible() {
        // Deliberately do not persist a foreign app as a future shortcut target.
        // Control Center frequently reports a system process here.
    }

    /// Call after a successful shortcut-driven activate.
    func scheduleReturnToPreviousApp() {
        pendingReturnToPreviousApp = true
        kickReturnIfNeeded()
    }

    /// Scene became active again (e.g. after we open ourselves). Retry return if pending.
    func handleSceneBecameActive() {
        guard pendingReturnToPreviousApp else { return }
        kickReturnIfNeeded()
    }

    func cancelReturnToPreviousApp() {
        pendingReturnToPreviousApp = false
        returnTask?.cancel()
        returnTask = nil
    }

    /// The containing app was opened directly by its keyboard extension. Once the
    /// session is ready, suspending should restore that extension's host app.
    func activateFromKeyboardAndReturn(to hostBundleID: String?) {
        cancelReturnToPreviousApp()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitUntilApplicationActive(timeout: 2.5)
            self.coordinator.setup(settings: self.settings)

            switch self.coordinator.state {
            case .inactive, .error:
                await self.coordinator.activate()
            case .ready, .recording, .transcribing, .polishing:
                break
            }

            guard self.coordinator.state == .ready else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)

            if let target = AppSwitcher.sanitize(hostBundleID) {
                for _ in 0..<4 {
                    _ = AppSwitcher.open(bundleID: target)
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    if AppSwitcher.isFrontmost(bundleID: target)
                        || UIApplication.shared.applicationState != .active {
                        return
                    }

                    _ = await AppSwitcher.openKnownURL(bundleID: target)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if AppSwitcher.isFrontmost(bundleID: target)
                        || UIApplication.shared.applicationState != .active {
                        return
                    }
                }
            }

            // When the host ID is unavailable, preserve the iOS "Back to …"
            // breadcrumb instead of guessing another application.
            AppSwitcher.suspendApplication()
        }
    }

    func waitUntilApplicationActive(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if UIApplication.shared.applicationState == .active {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Bring host app to foreground without relying on `openAppWhenRun` (so we can capture previous first).
    @discardableResult
    func bringHostAppToForeground() async -> Bool {
        if UIApplication.shared.applicationState == .active {
            return true
        }
        let opened = AppSwitcher.open(bundleID: AppSwitcher.ownBundleID)
        await waitUntilApplicationActive(timeout: 2.5)
        return opened || UIApplication.shared.applicationState == .active
    }

    private func resolvedReturnTarget() -> String? {
        AppSwitcher.sanitize(returnTargetBundleID)
    }

    private func kickReturnIfNeeded() {
        guard pendingReturnToPreviousApp else { return }
        returnTask?.cancel()
        returnTask = Task { @MainActor [weak self] in
            guard let self else { return }

            switch self.coordinator.state {
            case .ready, .recording, .transcribing, .polishing:
                break
            case .inactive, .error:
                // Failed path keeps the app open for the user to fix.
                self.pendingReturnToPreviousApp = false
                return
            }

            // Let the intent / Shortcuts host finish first so it does not re-foreground us.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled || !self.pendingReturnToPreviousApp { return }

            let target = self.resolvedReturnTarget()

            guard let target else {
                // Suspending without a target returns to Home when launched from
                // Control Center. Keep this app open instead of creating that dead end.
                self.logger.error("Return cancelled: no previous application was identified")
                self.pendingReturnToPreviousApp = false
                return
            }

            for attempt in 0..<10 {
                if Task.isCancelled || !self.pendingReturnToPreviousApp { return }

                // Prefer explicit reopen of the prior app (WeChat / Notes).
                // Plain suspend after Shortcuts often lands on SpringBoard Home.
                // Bundle-ID activation preserves the exact chat/note screen. Only
                // use an app URL if this iOS build rejects the private activation.
                var requested = AppSwitcher.open(bundleID: target)
                if requested {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
                if !AppSwitcher.isFrontmost(bundleID: target)
                    && UIApplication.shared.applicationState == .active {
                    requested = await AppSwitcher.openKnownURL(bundleID: target) || requested
                }
                if requested {
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    if AppSwitcher.isFrontmost(bundleID: target)
                        || UIApplication.shared.applicationState != .active {
                        self.logger.notice("Returned to \(target, privacy: .public) on attempt \(attempt + 1)")
                        self.pendingReturnToPreviousApp = false
                        return
                    }
                }

                // If Shortcuts pulled us back, retry a few times.
                if attempt == 4 {
                    _ = AppSwitcher.open(bundleID: target)
                }
            }

            self.pendingReturnToPreviousApp = false
        }
    }
}
