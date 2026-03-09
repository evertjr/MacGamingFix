import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import IOKit

/// Simple logic:
/// - If cursor was hidden and becomes visible at a protected edge → re-hide
/// - If cursor is already visible → don't touch it
class CursorFence {
    private(set) var isActive = false

    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "CursorFence.pollQueue", qos: .userInteractive)
    private var activityToken: NSObjectProtocol?
    private var didRegisterDisplayReconfigurationCallback = false
    private var gamePID: pid_t = 0
    private var wasCursorHidden = false
    private var lastHiddenAtEdge = false
    private var lastHiddenAtDockEdge = false
    private var lastHiddenAtHotCorner = false
    private var lastVisibleState: Bool?
    private var lastEdgeEntryUptime: TimeInterval?
    private var lastDockEntryUptime: TimeInterval?
    private var lastHotCornerEntryUptime: TimeInterval?
    private var hiddenEdgeSystemArmedUntil: TimeInterval?
    private var lastHiddenMousePosition: CGPoint?
    private var lastHiddenMouseMoveUptime: TimeInterval?
    private var lastHiddenDockMotionUptime: TimeInterval?
    private var lastEscapeKeyDownUptime: TimeInterval?
    private var pendingRevealDecisionAt: TimeInterval?
    private var pendingRevealStartMousePosition: CGPoint?
    private var didAttemptRehideForVisibleEpisode = false
    private var pendingSystemRehide = false
    private var pendingSystemRehideAt: TimeInterval?
    private var ourHideCount = 0
    private var lastBackgroundAssertionUptime: TimeInterval = 0
    private var lastDockRefreshUptime: TimeInterval = 0
    var onGameExit: (() -> Void)?
    var onCursorBecameHidden: (() -> Void)?

    // MARK: - Private API types

    private typealias CGSConnectionID = Int32
    private typealias SetConnectionPropertyFunc = @convention(c) (
        CGSConnectionID, CGSConnectionID, CFString, CFBoolean
    ) -> Void

    // MARK: - Symbol pointers

    private var cid: CGSConnectionID = 0
    private var setConnectionProperty: SetConnectionPropertyFunc?
    private var cursorIsVisible: (@convention(c) () -> Int32)?

    // Display-based hide/show (original approach)
    private var displayHideCursor: (@convention(c) (UInt32) -> Int32)?
    private var displayShowCursor: (@convention(c) (UInt32) -> Int32)?

    // Connection-based hide/show (different code path from display-based)
    private var connectionHideCursor: (@convention(c) (CGSConnectionID) -> Int32)?
    private var connectionShowCursor: (@convention(c) (CGSConnectionID) -> Int32)?

    // Cursor scale
    private var setCursorScale: (@convention(c) (CGSConnectionID, Double) -> Int32)?

    // Display capture detection
    private var displayIsCaptured: (@convention(c) (UInt32) -> Int32)?

    // IOHID cursor enable/disable
    private var ioHIDSetCursorEnable: (@convention(c) (io_connect_t, boolean_t) -> kern_return_t)?

    // Game connection ID resolution
    private var getProcessForPID: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)?
    private var getConnectionIDForPSN: (@convention(c) (
        CGSConnectionID,
        UnsafeMutablePointer<ProcessSerialNumber>,
        UnsafeMutablePointer<CGSConnectionID>
    ) -> Int32)?

    // MARK: - Tuning constants

    private let menuBarMargin: CGFloat = 30
    private let edgeMargin: CGFloat = 10
    private let edgeEntryWindow: TimeInterval = 0.12
    private let dockEntryWindow: TimeInterval = 0.08
    private let hotCornerEntryWindow: TimeInterval = 0.25
    private let edgeSystemArmWindow: TimeInterval = 0.2
    private let edgeMotionWindow: TimeInterval = 0.02
    private let dockMotionWindow: TimeInterval = 0.03
    private let hiddenMotionDeltaThreshold: CGFloat = 0.05
    private let gameMenuIntentWindow: TimeInterval = 0.45
    private let revealDecisionWindow: TimeInterval = 0.02
    private let revealDecisionMotionThreshold: CGFloat = 1.0
    private let dockRevealDecisionMotionThreshold: CGFloat = 0.2
    private let rehideFallbackWindow: TimeInterval = 0.04
    private let backgroundAssertionInterval: TimeInterval = 0.2
    private let dockRefreshInterval: TimeInterval = 0.6
    private let hiddenCursorScale: Double = 0.001
    private let visibleCursorScale: Double = 1.0
    private let hideFailureLogInterval: TimeInterval = 2.0
    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _, _, userInfo in
        guard let userInfo else { return }
        let fence = Unmanaged<CursorFence>.fromOpaque(userInfo).takeUnretainedValue()
        fence.pollQueue.async {
            fence.handleDisplayReconfiguration()
        }
    }

    // MARK: - Actuator state

    /// Which actuator mechanism is currently suppressing the cursor
    private enum ActiveActuator: CustomStringConvertible {
        case none
        case displayHide       // SLDisplayHideCursor (display-based)
        case connectionHide    // SLSHideCursor (connection-based)
        case cursorScale       // SLSSetCursorScale
        case ioHID             // IOHIDSetCursorEnable

        var description: String {
            switch self {
            case .none: return "none"
            case .displayHide: return "displayHide"
            case .connectionHide: return "connectionHide"
            case .cursorScale: return "cursorScale"
            case .ioHID: return "ioHID"
            }
        }
    }

    private var activeActuator: ActiveActuator = .none
    private var cursorScaleConnectionID: CGSConnectionID = 0
    private var ioHIDConnection: io_connect_t = 0
    private var trackedGameConnectionID: CGSConnectionID = 0
    private var lastHideFailureLogUptime: TimeInterval = 0

    private enum DockPosition { case bottom, left, right }
    private var dockPosition: DockPosition = .bottom
    private var dockThickness: CGFloat = 80

    // MARK: - Init

    init() {
        let handle = dlopen(nil, RTLD_LAZY)
        let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

        if let s = dlsym(handle, "CGSMainConnectionID") {
            cid = unsafeBitCast(s, to: (@convention(c) () -> CGSConnectionID).self)()
        }
        if let s = dlsym(handle, "CGSSetConnectionProperty") {
            setConnectionProperty = unsafeBitCast(s, to: SetConnectionPropertyFunc.self)
        }

        // Visibility check
        if let sl = skylight, let s = dlsym(sl, "SLCursorIsVisible") {
            cursorIsVisible = unsafeBitCast(s, to: (@convention(c) () -> Int32).self)
        }

        // Display-based hide/show (original approach)
        if let sl = skylight {
            if let s = dlsym(sl, "SLDisplayHideCursor") {
                displayHideCursor = unsafeBitCast(s, to: (@convention(c) (UInt32) -> Int32).self)
            }
            if let s = dlsym(sl, "SLDisplayShowCursor") {
                displayShowCursor = unsafeBitCast(s, to: (@convention(c) (UInt32) -> Int32).self)
            }
        }

        // Connection-based hide/show — different code path that may work when display-based doesn't
        resolveConnectionCursorSymbols(skylight: skylight, handle: handle)

        // Cursor scale
        resolveCursorScaleSymbol(skylight: skylight, handle: handle)

        // Display capture check — try public API first, then private
        resolveDisplayCapturedSymbol(skylight: skylight, handle: handle)

        // Game connection resolution
        resolveConnectionLookupSymbols(skylight: skylight, handle: handle)

        // IOKit HID cursor
        resolveIOHIDSymbol(iokit: iokit, handle: handle)

        printSymbolDiagnostics()
    }

    // MARK: - Symbol resolution helpers

    private func resolveConnectionCursorSymbols(skylight: UnsafeMutableRawPointer?, handle: UnsafeMutableRawPointer?) {
        let hideNames = ["SLSHideCursor", "CGSHideCursor"]
        let showNames = ["SLSShowCursor", "CGSShowCursor"]

        for name in hideNames {
            let sym = dlsym(skylight, name) ?? dlsym(handle, name)
            if let sym {
                connectionHideCursor = unsafeBitCast(sym, to: (@convention(c) (CGSConnectionID) -> Int32).self)
                break
            }
        }

        for name in showNames {
            let sym = dlsym(skylight, name) ?? dlsym(handle, name)
            if let sym {
                connectionShowCursor = unsafeBitCast(sym, to: (@convention(c) (CGSConnectionID) -> Int32).self)
                break
            }
        }
    }

    private func resolveCursorScaleSymbol(skylight: UnsafeMutableRawPointer?, handle: UnsafeMutableRawPointer?) {
        let names = ["SLSSetCursorScale", "CGSSetCursorScale"]
        for name in names {
            let sym = dlsym(skylight, name) ?? dlsym(handle, name)
            if let sym {
                setCursorScale = unsafeBitCast(sym, to: (@convention(c) (CGSConnectionID, Double) -> Int32).self)
                return
            }
        }
    }

    private func resolveDisplayCapturedSymbol(skylight: UnsafeMutableRawPointer?, handle: UnsafeMutableRawPointer?) {
        // CGDisplayIsCaptured is a public (deprecated) CG function — try it directly via handle
        let names = [
            "CGDisplayIsCaptured",
            "SLSDisplayIsCaptured",
            "CGSDisplayIsCaptured",
            "SLDisplayIsCaptured",
        ]
        for name in names {
            let sym = dlsym(handle, name) ?? dlsym(skylight, name)
            if let sym {
                displayIsCaptured = unsafeBitCast(sym, to: (@convention(c) (UInt32) -> Int32).self)
                return
            }
        }
    }

    private func resolveConnectionLookupSymbols(skylight: UnsafeMutableRawPointer?, handle: UnsafeMutableRawPointer?) {
        if let s = dlsym(skylight, "CGSGetConnectionIDForPSN") ?? dlsym(handle, "CGSGetConnectionIDForPSN") {
            getConnectionIDForPSN = unsafeBitCast(s, to: (@convention(c) (
                CGSConnectionID,
                UnsafeMutablePointer<ProcessSerialNumber>,
                UnsafeMutablePointer<CGSConnectionID>
            ) -> Int32).self)
        }

        if let s = dlsym(handle, "GetProcessForPID") {
            getProcessForPID = unsafeBitCast(s, to: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)
        }
    }

    private func resolveIOHIDSymbol(iokit: UnsafeMutableRawPointer?, handle: UnsafeMutableRawPointer?) {
        let sym = dlsym(iokit, "IOHIDSetCursorEnable") ?? dlsym(handle, "IOHIDSetCursorEnable")
        if let sym {
            ioHIDSetCursorEnable = unsafeBitCast(sym, to: (@convention(c) (io_connect_t, boolean_t) -> kern_return_t).self)
        }
    }

    private func printSymbolDiagnostics() {
        print("CursorFence: Symbol diagnostics:")
        print("  CGSMainConnectionID     → cid=\(cid)")
        print("  SetConnectionProperty   → \(setConnectionProperty != nil ? "OK" : "MISSING")")
        print("  SLCursorIsVisible       → \(cursorIsVisible != nil ? "OK" : "MISSING")")
        print("  SLDisplayHideCursor     → \(displayHideCursor != nil ? "OK" : "MISSING")")
        print("  SLDisplayShowCursor     → \(displayShowCursor != nil ? "OK" : "MISSING")")
        print("  SLSHideCursor           → \(connectionHideCursor != nil ? "OK" : "MISSING")")
        print("  SLSShowCursor           → \(connectionShowCursor != nil ? "OK" : "MISSING")")
        print("  SLSSetCursorScale       → \(setCursorScale != nil ? "OK" : "MISSING")")
        print("  CGDisplayIsCaptured     → \(displayIsCaptured != nil ? "OK" : "MISSING")")
        print("  IOHIDSetCursorEnable    → \(ioHIDSetCursorEnable != nil ? "OK" : "MISSING")")
        print("  GetProcessForPID        → \(getProcessForPID != nil ? "OK" : "MISSING")")
        print("  CGSGetConnectionIDForPSN→ \(getConnectionIDForPSN != nil ? "OK" : "MISSING")")
    }

    // MARK: - Public API

    func activate() {
        guard !isActive else { return }
        resetAllState()
        requestAccessibilityTrustIfNeeded()
        detectDock()
        setCursorBackgroundControl(enabled: true)
        registerDisplayReconfigurationCallback()

        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Maintain reliable cursor monitoring while game is frontmost"
            )
        }

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        pollTimer = timer

        isActive = true
        print("CursorFence: Active")
    }

    func deactivate() {
        guard isActive else { return }

        pollTimer?.cancel()
        pollTimer = nil

        releaseHides()
        unregisterDisplayReconfigurationCallback()
        setCursorBackgroundControl(enabled: false)
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        closeIOHIDConnection()
        resetAllState()

        isActive = false
        print("CursorFence: Deactivated")
    }

    func forceRevealCursor() {
        releaseForGameShow()

        guard let isVisible = cursorIsVisible else {
            lastVisibleState = true
            return
        }

        let display = CGMainDisplayID()
        var attempts = 0
        while isVisible() == 0 && attempts < 16 {
            _ = displayShowCursor?(display)
            attempts += 1
        }

        lastVisibleState = isVisible() != 0
    }

    func setTrackedGamePID(_ pid: pid_t) {
        guard pid > 0 else {
            gamePID = 0
            trackedGameConnectionID = 0
            return
        }

        gamePID = pid
        print("CursorFence: Tracking PID \(pid)")
        refreshTrackedGameConnectionID()
    }

    // MARK: - State management

    private func resetAllState() {
        gamePID = 0
        wasCursorHidden = false
        lastHiddenAtEdge = false
        lastHiddenAtDockEdge = false
        lastHiddenAtHotCorner = false
        lastVisibleState = nil
        lastEdgeEntryUptime = nil
        lastDockEntryUptime = nil
        lastHotCornerEntryUptime = nil
        hiddenEdgeSystemArmedUntil = nil
        lastHiddenMousePosition = nil
        lastHiddenMouseMoveUptime = nil
        lastHiddenDockMotionUptime = nil
        lastEscapeKeyDownUptime = nil
        pendingRevealDecisionAt = nil
        pendingRevealStartMousePosition = nil
        didAttemptRehideForVisibleEpisode = false
        pendingSystemRehide = false
        pendingSystemRehideAt = nil
        ourHideCount = 0
        lastBackgroundAssertionUptime = 0
        lastDockRefreshUptime = 0
        activeActuator = .none
        cursorScaleConnectionID = 0
        trackedGameConnectionID = 0
        lastHideFailureLogUptime = 0
    }

    // MARK: - Actuators: hide the cursor

    /// Try all available actuators in priority order. Returns true if one succeeded.
    private func attemptRehide(now: TimeInterval) {
        guard !didAttemptRehideForVisibleEpisode else { return }
        didAttemptRehideForVisibleEpisode = true

        let captured = mainDisplayIsCaptured()

        // 1. Cursor scale (changes rendering size, orthogonal to visibility state)
        if let result = tryCursorScaleHide(preferGameConnection: captured) {
            activeActuator = .cursorScale
            cursorScaleConnectionID = result
            return
        }

        // 2. Connection-based hide (different code path from display-based)
        if tryConnectionHide() {
            activeActuator = .connectionHide
            return
        }

        // 3. Display-based hide (original approach)
        if tryDisplayHide() {
            activeActuator = .displayHide
            ourHideCount += 1
            pendingSystemRehide = true
            pendingSystemRehideAt = now
            return
        }

        // 4. IOHID cursor disable (below WindowServer, nuclear option)
        if tryIOHIDHide() {
            activeActuator = .ioHID
            return
        }

        logHideFailureIfNeeded(
            now: now,
            message: "CursorFence: All actuators failed, captured=\(captured), gameConn=\(trackedGameConnectionID)"
        )
        releaseForGameShow()
    }

    private func tryCursorScaleHide(preferGameConnection: Bool) -> CGSConnectionID? {
        guard let setCursorScale else { return nil }

        // Try game's connection first if available
        if preferGameConnection || trackedGameConnectionID > 0 {
            ensureTrackedGameConnectionID()
            if trackedGameConnectionID > 0 {
                let status = setCursorScale(trackedGameConnectionID, hiddenCursorScale)
                if status == 0 {
                    return trackedGameConnectionID
                }
            }
        }

        // Try our own connection
        let status = setCursorScale(cid, hiddenCursorScale)
        if status == 0 {
            return cid
        }

        return nil
    }

    private func tryConnectionHide() -> Bool {
        guard let connectionHideCursor else { return false }

        // Try game's connection first
        if trackedGameConnectionID > 0 {
            let status = connectionHideCursor(trackedGameConnectionID)
            if status == 0 { return true }
        }

        // Try our own connection
        let status = connectionHideCursor(cid)
        return status == 0
    }

    private func tryDisplayHide() -> Bool {
        guard let displayHideCursor else { return false }
        let status = displayHideCursor(CGMainDisplayID())
        return status == 0
    }

    private func tryIOHIDHide() -> Bool {
        let status = applyIOHIDCursorEnabled(false)
        return status == KERN_SUCCESS
    }

    // MARK: - Actuators: release/show the cursor

    private func releaseHides() {
        switch activeActuator {
        case .cursorScale:
            let connID = cursorScaleConnectionID > 0 ? cursorScaleConnectionID : cid
            _ = setCursorScale?(connID, visibleCursorScale)
            cursorScaleConnectionID = 0

        case .connectionHide:
            // Show via connection-based API
            if let connectionShowCursor {
                _ = connectionShowCursor(cid)
                if trackedGameConnectionID > 0 {
                    _ = connectionShowCursor(trackedGameConnectionID)
                }
            }

        case .displayHide:
            let display = CGMainDisplayID()
            for _ in 0..<ourHideCount {
                _ = displayShowCursor?(display)
            }
            ourHideCount = 0

        case .ioHID:
            _ = applyIOHIDCursorEnabled(true)

        case .none:
            // Also clean up legacy hide count if any
            if ourHideCount > 0 {
                let display = CGMainDisplayID()
                for _ in 0..<ourHideCount {
                    _ = displayShowCursor?(display)
                }
                ourHideCount = 0
            }
        }

        activeActuator = .none
    }

    // MARK: - IOHID helpers

    private func ensureIOHIDConnection() -> Bool {
        if ioHIDConnection != 0 { return true }

        guard let matching = IOServiceMatching("IOHIDSystem") else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 1, &connection)
        guard status == KERN_SUCCESS else { return false }

        ioHIDConnection = connection
        return true
    }

    private func closeIOHIDConnection() {
        guard ioHIDConnection != 0 else { return }
        IOServiceClose(ioHIDConnection)
        ioHIDConnection = 0
    }

    private func applyIOHIDCursorEnabled(_ enabled: Bool) -> kern_return_t {
        guard let ioHIDSetCursorEnable else { return kern_return_t(KERN_FAILURE) }
        guard ensureIOHIDConnection() else { return kern_return_t(KERN_FAILURE) }

        let status = ioHIDSetCursorEnable(ioHIDConnection, enabled ? 1 : 0)
        if status == KERN_SUCCESS { return status }

        // Retry with fresh connection
        closeIOHIDConnection()
        guard ensureIOHIDConnection() else { return status }
        return ioHIDSetCursorEnable(ioHIDConnection, enabled ? 1 : 0)
    }

    // MARK: - Game connection resolution

    private func ensureTrackedGameConnectionID() {
        guard trackedGameConnectionID <= 0 else { return }
        refreshTrackedGameConnectionID()
    }

    private func refreshTrackedGameConnectionID() {
        guard gamePID > 0 else {
            trackedGameConnectionID = 0
            return
        }
        guard let getConnectionIDForPSN, let getProcessForPID else { return }

        var psn = ProcessSerialNumber()
        guard getProcessForPID(gamePID, &psn) == 0 else {
            trackedGameConnectionID = 0
            return
        }

        var resolved: CGSConnectionID = 0
        guard getConnectionIDForPSN(cid, &psn, &resolved) == 0, resolved > 0 else {
            trackedGameConnectionID = 0
            return
        }

        if trackedGameConnectionID != resolved {
            trackedGameConnectionID = resolved
            print("CursorFence: Game connection ID \(resolved)")
        }
    }

    // MARK: - WindowServer helpers

    private func setCursorBackgroundControl(enabled: Bool) {
        let flag = enabled ? kCFBooleanTrue : kCFBooleanFalse
        guard let flag else { return }
        setConnectionProperty?(cid, cid, "SetsCursorInBackground" as CFString, flag)
    }

    private func mainDisplayIsCaptured() -> Bool {
        guard let displayIsCaptured else { return false }
        return displayIsCaptured(CGMainDisplayID()) != 0
    }

    private func requestAccessibilityTrustIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Display reconfiguration

    private func registerDisplayReconfigurationCallback() {
        guard !didRegisterDisplayReconfigurationCallback else { return }
        let status = CGDisplayRegisterReconfigurationCallback(
            CursorFence.displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard status == .success else {
            print("CursorFence: Failed to register display callback (\(status.rawValue))")
            return
        }
        didRegisterDisplayReconfigurationCallback = true
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard didRegisterDisplayReconfigurationCallback else { return }
        let _ = CGDisplayRemoveReconfigurationCallback(
            CursorFence.displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        didRegisterDisplayReconfigurationCallback = false
    }

    private func handleDisplayReconfiguration() {
        guard isActive else { return }
        detectDock()
        setCursorBackgroundControl(enabled: true)
        if gamePID > 0 {
            refreshTrackedGameConnectionID()
        }
        lastBackgroundAssertionUptime = ProcessInfo.processInfo.systemUptime
        lastDockRefreshUptime = lastBackgroundAssertionUptime
    }

    // MARK: - Screen geometry

    private func detectDock() {
        guard let screen = NSScreen.main else { return }
        let previousPosition = dockPosition
        let previousThickness = dockThickness
        let full = screen.frame
        let visible = screen.visibleFrame

        let bottomGap = visible.minY - full.minY
        let leftGap = visible.minX - full.minX
        let rightGap = full.maxX - visible.maxX

        let minSize: CGFloat = 10
        if leftGap > minSize && leftGap >= rightGap && leftGap >= bottomGap {
            dockPosition = .left
            dockThickness = leftGap + 20
        } else if rightGap > minSize && rightGap >= leftGap && rightGap >= bottomGap {
            dockPosition = .right
            dockThickness = rightGap + 20
        } else {
            dockPosition = .bottom
            dockThickness = max(bottomGap + 20, 80)
        }

        if previousPosition != dockPosition || abs(previousThickness - dockThickness) >= 1 {
            print("CursorFence: Dock at \(dockPosition), thickness \(dockThickness)")
        }
    }

    private func screenForMouse() -> NSScreen? {
        let pos = NSEvent.mouseLocation
        if let matched = NSScreen.screens.first(where: { $0.frame.contains(pos) }) {
            return matched
        }
        return NSScreen.main
    }

    private func isAtMenuBar() -> Bool {
        let pos = NSEvent.mouseLocation
        guard let screen = screenForMouse() else { return false }
        return (screen.frame.maxY - pos.y) < menuBarMargin
    }

    private func isAtHotCorner() -> Bool {
        let pos = NSEvent.mouseLocation
        guard let screen = screenForMouse() else { return false }
        let frame = screen.frame
        let nearBottom = (pos.y - frame.minY) < edgeMargin
        let nearTop = (frame.maxY - pos.y) < edgeMargin
        let nearLeft = (pos.x - frame.minX) < edgeMargin
        let nearRight = (frame.maxX - pos.x) < edgeMargin
        return (nearBottom || nearTop) && (nearLeft || nearRight)
    }

    private func isAtDockEdge() -> Bool {
        let pos = NSEvent.mouseLocation
        guard let screen = screenForMouse() else { return false }
        guard screen == NSScreen.main else { return false }
        let frame = screen.frame
        let distanceToBottom = pos.y - frame.minY
        let distanceToLeft = pos.x - frame.minX
        let distanceToRight = frame.maxX - pos.x

        switch dockPosition {
        case .bottom:
            return distanceToBottom < dockThickness
        case .left:
            return distanceToLeft < dockThickness
        case .right:
            return distanceToRight < dockThickness
        }
    }

    private func isAtEdge() -> Bool {
        let pos = NSEvent.mouseLocation
        guard let screen = screenForMouse() else { return false }
        let frame = screen.frame
        let distanceToBottom = pos.y - frame.minY
        let distanceToLeft = pos.x - frame.minX
        let distanceToRight = frame.maxX - pos.x

        let nearBottom = distanceToBottom < edgeMargin
        let nearLeft = distanceToLeft < edgeMargin
        let nearRight = distanceToRight < edgeMargin

        return isAtDockEdge() || nearBottom || nearLeft || nearRight
    }

    // MARK: - Decision helpers

    private func releaseForGameShow() {
        releaseHides()
        wasCursorHidden = false
        lastHiddenAtEdge = false
        lastHiddenAtDockEdge = false
        lastHiddenAtHotCorner = false
        lastEdgeEntryUptime = nil
        lastDockEntryUptime = nil
        lastHotCornerEntryUptime = nil
        hiddenEdgeSystemArmedUntil = nil
        lastHiddenMousePosition = nil
        lastHiddenMouseMoveUptime = nil
        lastHiddenDockMotionUptime = nil
        pendingRevealDecisionAt = nil
        pendingRevealStartMousePosition = nil
        didAttemptRehideForVisibleEpisode = false
        pendingSystemRehide = false
        pendingSystemRehideAt = nil
    }

    private func logHideFailureIfNeeded(now: TimeInterval, message: String) {
        guard (now - lastHideFailureLogUptime) >= hideFailureLogInterval else { return }
        lastHideFailureLogUptime = now
        print(message)
    }

    private func shouldRehideForMenuBarClick() -> Bool {
        isAtMenuBar() && NSEvent.pressedMouseButtons != 0
    }

    private func hasRecentGameMenuIntent(now: TimeInterval) -> Bool {
        guard let escapeDownAt = lastEscapeKeyDownUptime else { return false }
        return (now - escapeDownAt) <= gameMenuIntentWindow
    }

    private func shouldForceGameplayRehide(now: TimeInterval) -> Bool {
        NSEvent.pressedMouseButtons != 0 && !hasRecentGameMenuIntent(now: now)
    }

    private func hasRecentDockLeakEvidence(now: TimeInterval) -> Bool {
        if let dockEntryTime = lastDockEntryUptime, (now - dockEntryTime) <= dockEntryWindow {
            return true
        }
        if let dockMotionTime = lastHiddenDockMotionUptime, (now - dockMotionTime) <= dockMotionWindow {
            return true
        }
        return false
    }

    private func shouldRehideForSystemReveal(now: TimeInterval) -> Bool {
        let atEdge = isAtEdge()
        let atDockEdge = isAtDockEdge()
        let atHotCorner = isAtHotCorner()

        let hasRecentEdgeEntry: Bool
        if let edgeEntryTime = lastEdgeEntryUptime {
            hasRecentEdgeEntry = (now - edgeEntryTime) <= edgeEntryWindow
        } else {
            hasRecentEdgeEntry = false
        }

        let hasRecentDockEntry: Bool
        if let dockEntryTime = lastDockEntryUptime {
            hasRecentDockEntry = (now - dockEntryTime) <= dockEntryWindow
        } else {
            hasRecentDockEntry = false
        }

        let hasRecentDockMotion: Bool
        if let dockMotionTime = lastHiddenDockMotionUptime {
            hasRecentDockMotion = (now - dockMotionTime) <= dockMotionWindow
        } else {
            hasRecentDockMotion = false
        }

        let hasRecentHotCornerEntry: Bool
        if let hotCornerEntryTime = lastHotCornerEntryUptime {
            hasRecentHotCornerEntry = (now - hotCornerEntryTime) <= hotCornerEntryWindow
        } else {
            hasRecentHotCornerEntry = false
        }

        if atDockEdge && hasRecentDockEntry { return true }
        if atHotCorner && hasRecentHotCornerEntry { return true }
        if atDockEdge && hasRecentDockMotion { return true }

        let hasRecentHiddenMotion: Bool
        if let movedAt = lastHiddenMouseMoveUptime {
            hasRecentHiddenMotion = (now - movedAt) <= edgeMotionWindow
        } else {
            hasRecentHiddenMotion = false
        }

        if let armedUntil = hiddenEdgeSystemArmedUntil {
            if now <= armedUntil {
                if atDockEdge { return true }
                if atHotCorner { return true }
                if atEdge && (hasRecentEdgeEntry || hasRecentHiddenMotion) { return true }
                return false
            }
            hiddenEdgeSystemArmedUntil = nil
        }

        if atEdge && hasRecentEdgeEntry { return true }
        if atEdge && hasRecentHiddenMotion { return true }

        return false
    }

    // MARK: - Poll loop (decision engine unchanged)

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime

        if (now - lastBackgroundAssertionUptime) >= backgroundAssertionInterval {
            setCursorBackgroundControl(enabled: true)
            lastBackgroundAssertionUptime = now
        }

        if (now - lastDockRefreshUptime) >= dockRefreshInterval {
            detectDock()
            lastDockRefreshUptime = now
        }

        if gamePID > 0 && kill(gamePID, 0) != 0 && errno == ESRCH {
            DispatchQueue.main.async { [weak self] in
                self?.onGameExit?()
            }
            return
        }

        if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(53)) {
            lastEscapeKeyDownUptime = ProcessInfo.processInfo.systemUptime
        }

        guard let isVisible = cursorIsVisible else { return }
        let visible = isVisible() != 0

        guard let previousVisible = lastVisibleState else {
            lastVisibleState = visible
            if !visible {
                wasCursorHidden = true
                lastHiddenAtEdge = isAtEdge()
                lastHiddenAtDockEdge = isAtDockEdge()
                lastHiddenAtHotCorner = isAtHotCorner()
            }
            return
        }

        // --- Cursor is hidden ---
        if !visible {
            // If we were using scale or IOHID (cursor "visible" to system but visually hidden),
            // and the game itself now hid the cursor, release our actuator.
            if activeActuator == .cursorScale || activeActuator == .ioHID {
                releaseHides()
            }

            let atEdge = isAtEdge()
            let atDockEdge = isAtDockEdge()
            let atHotCorner = isAtHotCorner()
            let becameHidden = previousVisible
            let mousePosition = NSEvent.mouseLocation

            if becameHidden {
                didAttemptRehideForVisibleEpisode = false
                lastHiddenAtEdge = atEdge
                lastHiddenAtDockEdge = atDockEdge
                lastHiddenAtHotCorner = atHotCorner
                hiddenEdgeSystemArmedUntil = pendingSystemRehide ? (now + edgeSystemArmWindow) : nil
                lastEdgeEntryUptime = pendingSystemRehide ? now : nil
                lastDockEntryUptime = pendingSystemRehide && atDockEdge ? now : nil
                lastHotCornerEntryUptime = pendingSystemRehide && atHotCorner ? now : nil
                lastHiddenMousePosition = mousePosition
                lastHiddenMouseMoveUptime = nil
                lastHiddenDockMotionUptime = nil
                pendingSystemRehide = false
                pendingSystemRehideAt = nil
                pendingRevealDecisionAt = nil
                pendingRevealStartMousePosition = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onCursorBecameHidden?()
                }
            } else {
                if atEdge && !lastHiddenAtEdge {
                    lastEdgeEntryUptime = now
                    hiddenEdgeSystemArmedUntil = now + edgeSystemArmWindow
                }
                if atDockEdge && !lastHiddenAtDockEdge {
                    lastDockEntryUptime = now
                    hiddenEdgeSystemArmedUntil = now + edgeSystemArmWindow
                }
                if atHotCorner && !lastHiddenAtHotCorner {
                    lastHotCornerEntryUptime = now
                    hiddenEdgeSystemArmedUntil = now + edgeSystemArmWindow
                }
                lastHiddenAtEdge = atEdge
                lastHiddenAtDockEdge = atDockEdge
                lastHiddenAtHotCorner = atHotCorner
            }

            if !becameHidden {
                if let lastPosition = lastHiddenMousePosition {
                    let dx = abs(mousePosition.x - lastPosition.x)
                    let dy = abs(mousePosition.y - lastPosition.y)
                    if dx >= hiddenMotionDeltaThreshold || dy >= hiddenMotionDeltaThreshold {
                        lastHiddenMouseMoveUptime = now
                        if atDockEdge {
                            lastHiddenDockMotionUptime = now
                        }
                    }
                }
                lastHiddenMousePosition = mousePosition
            }

            wasCursorHidden = true
            lastVisibleState = false
            return
        }

        // --- Cursor is visible but was never hidden by game → ignore ---
        guard wasCursorHidden else {
            lastVisibleState = true
            return
        }

        // --- Cursor is visible (and was previously hidden) ---
        let becameVisible = !previousVisible
        if !becameVisible {
            // Cursor scale doesn't change SLCursorIsVisible, so handle escape intent
            if activeActuator == .cursorScale && hasRecentGameMenuIntent(now: now) {
                releaseForGameShow()
                lastVisibleState = true
                return
            }

            if let pendingAt = pendingRevealDecisionAt {
                if shouldForceGameplayRehide(now: now) {
                    pendingRevealDecisionAt = nil
                    pendingRevealStartMousePosition = nil
                    attemptRehide(now: now)
                    lastVisibleState = true
                    return
                }

                if hasRecentGameMenuIntent(now: now) {
                    pendingRevealDecisionAt = nil
                    pendingRevealStartMousePosition = nil
                    releaseForGameShow()
                    lastVisibleState = true
                    return
                }

                if !isAtEdge() {
                    pendingRevealDecisionAt = nil
                    pendingRevealStartMousePosition = nil
                    releaseForGameShow()
                    lastVisibleState = true
                    return
                }

                if shouldRehideForSystemReveal(now: now) {
                    if isAtHotCorner() {
                        pendingRevealDecisionAt = nil
                        pendingRevealStartMousePosition = nil
                        attemptRehide(now: now)
                        lastVisibleState = true
                        return
                    }

                    if let startPos = pendingRevealStartMousePosition {
                        let pos = NSEvent.mouseLocation
                        let movedDistance = max(abs(pos.x - startPos.x), abs(pos.y - startPos.y))
                        let requiredMotion = isAtDockEdge()
                            ? dockRevealDecisionMotionThreshold
                            : revealDecisionMotionThreshold

                        if movedDistance >= requiredMotion {
                            pendingRevealDecisionAt = nil
                            pendingRevealStartMousePosition = nil
                            attemptRehide(now: now)
                            lastVisibleState = true
                            return
                        }
                    }
                }

                if (now - pendingAt) >= revealDecisionWindow {
                    pendingRevealDecisionAt = nil
                    pendingRevealStartMousePosition = nil
                    releaseForGameShow()
                }

                lastVisibleState = true
                return
            }

            if pendingSystemRehide,
                let attemptedAt = pendingSystemRehideAt,
                (now - attemptedAt) >= rehideFallbackWindow
            {
                releaseForGameShow()
            }
            lastVisibleState = true
            return
        }

        // --- Cursor just became visible (transition) ---
        didAttemptRehideForVisibleEpisode = false

        if shouldRehideForMenuBarClick() {
            attemptRehide(now: now)
            lastVisibleState = true
            return
        }

        if shouldForceGameplayRehide(now: now) {
            attemptRehide(now: now)
            lastVisibleState = true
            return
        }

        if hasRecentGameMenuIntent(now: now) {
            releaseForGameShow()
            lastVisibleState = true
            return
        }

        if hasRecentDockLeakEvidence(now: now) {
            attemptRehide(now: now)
            lastVisibleState = true
            return
        }

        if isAtHotCorner() && shouldRehideForSystemReveal(now: now) {
            attemptRehide(now: now)
            lastVisibleState = true
            return
        }

        if isAtEdge() {
            pendingRevealDecisionAt = now
            pendingRevealStartMousePosition = NSEvent.mouseLocation
            lastVisibleState = true
            return
        }

        releaseForGameShow()
        lastVisibleState = true
    }
}
