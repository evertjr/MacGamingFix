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
    @Published var fnKeysEnabled = false {
        didSet {
            guard fnKeysEnabled != oldValue else { return }
            applyFnKeysPreference()
        }
    }
    @Published var audioFixEnabled = false {
        didSet {
            guard audioFixEnabled != oldValue else { return }
            applyAudioFixPreference()
        }
    }
    @Published var cursorShortcut: CursorShortcut {
        didSet {
            guard cursorShortcut != oldValue else { return }
            cursorShortcut.save()
            applyCursorShortcut()
        }
    }
    @Published private(set) var cursorShortcutRegistrationFailed = false
    @Published private(set) var cursorShortcutFullscreenSupported = false
    @Published var manualGameSelection: ManualGameSelection? {
        didSet {
            guard manualGameSelection != oldValue else { return }
            applyManualGameSelection()
        }
    }

    private let cursorFence = CursorFence()
    private let gameMode = GameModeActivator()
    private let fnKeyMode = FunctionKeyMode()
    private let audioSampleRate = AudioSampleRate()
    private lazy var cursorToggleHotKey = GlobalHotKey { [weak self] in
        self?.toggleCursorVisibility()
    }
    private lazy var cursorToggleEventTap = KeyboardEventTap { [weak self] in
        self?.toggleCursorVisibility()
    }
    private var trackedGamePID: pid_t?

    private var appObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    var isGameModeAvailable: Bool { gameMode.isAvailable }

    init() {
        cursorShortcut = CursorShortcut.loadSaved()

        // Ensure game mode is reset from any previous session
        gameMode.deactivate()
        applyCursorShortcut()

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

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else {
                return
            }

            if self.manualGameSelection?.pid == app.processIdentifier {
                self.manualGameSelection = nil
            }
        }
    }

    func activate() {
        guard !isActive else { return }

        if let manualPID = validatedManualSelectionPID() {
            trackedGamePID = manualPID
            cursorFence.setTrackedGamePID(manualPID)
        } else {
            manualGameSelection = nil
            trackedGamePID = nil
            cursorFence.setTrackedGamePID(0)
        }

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

    func toggleCursorVisibility() {
        guard isActive else { return }
        cursorFence.toggleCursorVisibility()
    }

    func resetCursorShortcut() {
        cursorShortcut = .defaultValue
    }

    func cleanup() {
        if isActive { deactivate() }
        cursorToggleHotKey.unregister()
        cursorToggleEventTap.stop()
        fnKeyMode.deactivate()
        audioSampleRate.deactivate()
    }

    func requestFullscreenShortcutPermission() {
        if AccessibilityPermission.isGranted {
            applyCursorShortcut()
            return
        }

        AccessibilityPermission.request()
        AccessibilityPermission.openSettings()
    }

    func refreshFullscreenShortcutStatus() {
        guard AccessibilityPermission.isGranted else { return }
        guard !cursorShortcutFullscreenSupported else { return }
        applyCursorShortcut()
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
        guard manualGameSelection == nil else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.activationPolicy == .regular else { return }

        let myBundleID = Bundle.main.bundleIdentifier
        guard app.bundleIdentifier != myBundleID else { return }

        trackedGamePID = app.processIdentifier
        cursorFence.setTrackedGamePID(app.processIdentifier)
    }

    private func validatedManualSelectionPID() -> pid_t? {
        guard let pid = manualGameSelection?.pid, pid > 0 else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return nil
        }
        return pid
    }

    private func applyManualGameSelection() {
        guard isActive else { return }

        if let pid = validatedManualSelectionPID() {
            trackedGamePID = pid
            cursorFence.setTrackedGamePID(pid)
            return
        }

        trackedGamePID = nil
        cursorFence.setTrackedGamePID(0)
    }

    private func applyGameModePreference() {
        gameMode.sync(enabled: isActive && gameModeEnabled && isGameModeAvailable)
    }

    private func applyFnKeysPreference() {
        if fnKeysEnabled {
            fnKeyMode.activate()
        } else {
            fnKeyMode.deactivate()
        }
    }

    private func applyAudioFixPreference() {
        if audioFixEnabled {
            audioSampleRate.activate()
        } else {
            audioSampleRate.deactivate()
        }
    }

    private func applyCursorShortcut() {
        let carbonRegistered = cursorToggleHotKey.register(cursorShortcut)
        let tapStarted = cursorToggleEventTap.start(cursorShortcut)

        cursorShortcutFullscreenSupported = tapStarted
        cursorShortcutRegistrationFailed = !(carbonRegistered || tapStarted)
    }
}
