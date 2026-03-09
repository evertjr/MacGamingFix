import SwiftUI

class AppState: ObservableObject {
    @Published var isActive = false
    @Published var isLogging = false
    @Published var gameModeEnabled = true {
        didSet {
            guard gameModeEnabled != oldValue else { return }
            applyGameModePreference()
        }
    }

    private let cursorFence = CursorFence()
    private let gameMode = GameModeActivator()
    private var trackedGamePID: pid_t?

    private var appObserver: NSObjectProtocol?

    var isGameModeAvailable: Bool { gameMode.isAvailable }

    init() {
        // Ensure game mode is reset from any previous session
        gameMode.deactivate()

        cursorFence.onGameExit = { [weak self] in
            self?.deactivate()
        }
        cursorFence.onCursorBecameHidden = { [weak self] in
            self?.captureTrackedGameFromFrontmostIfNeeded()
        }

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }

            guard self.isActive else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else {
                return
            }

            self.handleActivatedApplication(app)
        }
    }

    func activate() {
        guard !isActive else { return }

        trackedGamePID = nil
        cursorFence.setTrackedGamePID(0)
        cursorFence.activate()

        if cursorFence.isActive {
            isActive = true
            applyGameModePreference()
        }
    }

    func deactivate() {
        guard isActive else { return }

        cursorFence.deactivate()
        trackedGamePID = nil
        isActive = false
        applyGameModePreference()
    }

    func toggleLogging() {
        isLogging.toggle()
        if isLogging {
            cursorFence.startLogging()
        } else {
            cursorFence.stopLogging()
        }
    }

    func copyLogToClipboard() {
        let log = cursorFence.exportLog()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.isEmpty ? "(no log entries)" : log, forType: .string)
    }

    func installXcodeTools() {
        GameModeActivator.promptInstallXcodeTools()
    }

    func cleanup() {
        if isActive { deactivate() }
    }

    private func handleActivatedApplication(_ app: NSRunningApplication) {
        let myBundleID = Bundle.main.bundleIdentifier
        if app.bundleIdentifier == myBundleID {
            cursorFence.forceRevealCursor()
            return
        }

        guard app.activationPolicy == .regular else { return }
        guard let trackedGamePID else { return }

        if app.processIdentifier != trackedGamePID {
            cursorFence.forceRevealCursor()
        }
    }

    private func captureTrackedGameFromFrontmostIfNeeded() {
        guard isActive, trackedGamePID == nil else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.activationPolicy == .regular else { return }

        let myBundleID = Bundle.main.bundleIdentifier
        guard app.bundleIdentifier != myBundleID else { return }

        trackedGamePID = app.processIdentifier
        cursorFence.setTrackedGamePID(app.processIdentifier)
    }

    private func applyGameModePreference() {
        gameMode.sync(enabled: isActive && gameModeEnabled && isGameModeAvailable)
    }
}
