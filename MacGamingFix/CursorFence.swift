import AppKit
import CoreGraphics

/// Simple logic:
/// - If cursor was hidden and becomes visible at a protected edge → re-hide
/// - If cursor is already visible → don't touch it
class CursorFence {
    private(set) var isActive = false

    private var pollTimer: DispatchSourceTimer?
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
    var onGameExit: (() -> Void)?
    var onCursorBecameHidden: (() -> Void)?

    private typealias CGSConnectionID = Int32
    private typealias SetConnectionPropertyFunc = @convention(c) (
        CGSConnectionID, CGSConnectionID, CFString, CFBoolean
    ) -> Void

    private var cid: CGSConnectionID = 0
    private var setConnectionProperty: SetConnectionPropertyFunc?
    private var cursorIsVisible: (@convention(c) () -> Int32)?
    private var displayHideCursor: (@convention(c) (UInt32) -> Int32)?
    private var displayShowCursor: (@convention(c) (UInt32) -> Int32)?

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

    private enum DockPosition { case bottom, left, right }
    private var dockPosition: DockPosition = .bottom
    private var dockThickness: CGFloat = 80

    init() {
        let handle = dlopen(nil, RTLD_LAZY)
        let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        if let s = dlsym(handle, "CGSMainConnectionID") {
            cid = unsafeBitCast(s, to: (@convention(c) () -> CGSConnectionID).self)()
        }
        if let s = dlsym(handle, "CGSSetConnectionProperty") {
            setConnectionProperty = unsafeBitCast(s, to: SetConnectionPropertyFunc.self)
        }
        if let sl = skylight {
            if let s = dlsym(sl, "SLCursorIsVisible") {
                cursorIsVisible = unsafeBitCast(s, to: (@convention(c) () -> Int32).self)
            }
            if let s = dlsym(sl, "SLDisplayHideCursor") {
                displayHideCursor = unsafeBitCast(s, to: (@convention(c) (UInt32) -> Int32).self)
            }
            if let s = dlsym(sl, "SLDisplayShowCursor") {
                displayShowCursor = unsafeBitCast(s, to: (@convention(c) (UInt32) -> Int32).self)
            }
        }
    }

    func activate() {
        guard !isActive else { return }
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

        // Snapshot dock position/size for edge-zone detection
        detectDock()

        setConnectionProperty?(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .microseconds(500))
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

        // Undo exactly our hides
        releaseHides()

        setConnectionProperty?(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanFalse)

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
            return
        }

        gamePID = pid
        print("CursorFence: Tracking PID \(pid)")
    }

    private func releaseHides() {
        guard ourHideCount > 0 else { return }
        let display = CGMainDisplayID()
        for _ in 0..<ourHideCount {
            _ = displayShowCursor?(display)
        }
        ourHideCount = 0
    }

    private func detectDock() {
        guard let screen = NSScreen.main else { return }
        let full = screen.frame
        let visible = screen.visibleFrame

        let bottomGap = visible.minY - full.minY
        let leftGap = visible.minX - full.minX
        let rightGap = full.maxX - visible.maxX

        // The largest gap (excluding menubar at top) is where the dock is
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

        print("CursorFence: Dock at \(dockPosition), thickness \(dockThickness)")
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

    /// Any screen edge: dock zone + all corners + left/right edges (hot corners, etc.)
    private func isAtEdge() -> Bool {
        let pos = NSEvent.mouseLocation
        guard let screen = screenForMouse() else { return false }
        let frame = screen.frame
        let distanceToBottom = pos.y - frame.minY
        let distanceToLeft = pos.x - frame.minX
        let distanceToRight = frame.maxX - pos.x

        // All other edges (hot corners, screen edges)
        let nearBottom = distanceToBottom < edgeMargin
        let nearLeft = distanceToLeft < edgeMargin
        let nearRight = distanceToRight < edgeMargin

        return isAtDockEdge() || nearBottom || nearLeft || nearRight
    }

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

    private func attemptRehide(now: TimeInterval) {
        guard !didAttemptRehideForVisibleEpisode else { return }
        didAttemptRehideForVisibleEpisode = true

        let status = displayHideCursor?(CGMainDisplayID()) ?? -1
        if status == 0 {
            ourHideCount += 1
            pendingSystemRehide = true
            pendingSystemRehideAt = now
            return
        }

        // If we fail to hide, avoid keeping stale state that can trap the cursor hidden.
        releaseForGameShow()
    }

    private func shouldRehideForMenuBarClick() -> Bool {
        let atMenuBar = isAtMenuBar()
        let mouseDown = NSEvent.pressedMouseButtons != 0
        return atMenuBar && mouseDown
    }

    private func hasRecentGameMenuIntent(now: TimeInterval) -> Bool {
        guard let escapeDownAt = lastEscapeKeyDownUptime else { return false }
        return (now - escapeDownAt) <= gameMenuIntentWindow
    }

    private func shouldForceGameplayRehide(now: TimeInterval) -> Bool {
        let mouseButtonDown = NSEvent.pressedMouseButtons != 0
        return mouseButtonDown && !hasRecentGameMenuIntent(now: now)
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

        if atDockEdge && hasRecentDockEntry {
            return true
        }

        if atHotCorner && hasRecentHotCornerEntry {
            return true
        }

        if atDockEdge && hasRecentDockMotion {
            return true
        }

        let hasRecentHiddenMotion: Bool
        if let movedAt = lastHiddenMouseMoveUptime {
            hasRecentHiddenMotion = (now - movedAt) <= edgeMotionWindow
        } else {
            hasRecentHiddenMotion = false
        }

        if let armedUntil = hiddenEdgeSystemArmedUntil {
            if now <= armedUntil {
                if atDockEdge {
                    return true
                }
                if atHotCorner {
                    return true
                }
                if atEdge && (hasRecentEdgeEntry || hasRecentHiddenMotion) {
                    return true
                }
                return false
            }
            hiddenEdgeSystemArmedUntil = nil
        }

        if atEdge && hasRecentEdgeEntry {
            return true
        }

        if atEdge && hasRecentHiddenMotion {
            return true
        }

        return false
    }

    private func poll() {
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
        let now = ProcessInfo.processInfo.systemUptime

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

        if !visible {
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

        guard wasCursorHidden else {
            lastVisibleState = true
            return
        }

        let becameVisible = !previousVisible
        if !becameVisible {
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
                // If a system-rehide attempt didn't make the cursor hidden quickly,
                // assume this is a game-driven show and release our hides.
                releaseForGameShow()
            }
            lastVisibleState = true
            return
        }

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
