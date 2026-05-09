import ApplicationServices
import Carbon
import SwiftUI

struct CursorShortcut: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let keyName: String

    static let defaultValue = CursorShortcut(
        keyCode: 4,
        modifiers: [.control, .option, .command],
        keyName: "H"
    )

    var displayName: String {
        let symbols = [
            modifiers.contains(.control) ? "⌃" : nil,
            modifiers.contains(.option) ? "⌥" : nil,
            modifiers.contains(.shift) ? "⇧" : nil,
            modifiers.contains(.command) ? "⌘" : nil,
        ].compactMap { $0 }.joined()

        return "\(symbols)\(keyName)"
    }

    var storageValue: String {
        "\(keyCode)|\(modifiers.rawValue)|\(keyName)"
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.cursorShortcutFlags
        self.keyName = keyName
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.cursorShortcutFlags
        guard modifiers.hasPrimaryShortcutModifier else { return nil }
        guard event.keyCode != 53 else { return nil }
        guard let keyName = Self.keyName(for: event) else { return nil }

        self.keyCode = event.keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let keyCode = UInt16(parts[0]) else { return nil }
        guard let rawModifiers = UInt(parts[1]) else { return nil }

        let modifiers = NSEvent.ModifierFlags(rawValue: rawModifiers).cursorShortcutFlags
        guard modifiers.hasPrimaryShortcutModifier else { return nil }

        let keyName = String(parts[2])
        guard !keyName.isEmpty else { return nil }

        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    static func loadSaved() -> CursorShortcut {
        guard let value = UserDefaults.standard.string(forKey: storageKey),
            let shortcut = CursorShortcut(storageValue: value)
        else {
            return defaultValue
        }

        return shortcut
    }

    func save() {
        UserDefaults.standard.set(storageValue, forKey: Self.storageKey)
    }

    private static let storageKey = "CursorToggleShortcut"

    private static let specialKeyNames: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        71: "Clear",
        76: "Enter",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        114: "Help",
        115: "Home",
        116: "Page Up",
        117: "Forward Delete",
        118: "F4",
        119: "End",
        120: "F2",
        121: "Page Down",
        122: "F1",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑",
    ]

    private static func keyName(for event: NSEvent) -> String? {
        if let specialKeyName = specialKeyNames[event.keyCode] {
            return specialKeyName
        }

        guard let characters = event.charactersIgnoringModifiers else { return nil }
        guard let scalar = characters.unicodeScalars.first else { return nil }

        let keyName = String(scalar).uppercased()
        guard !keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return keyName
    }
}

final class GlobalHotKey {
    private let action: () -> Void
    private let signature = OSType(0x4D474658)
    private let identifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
    }

    @discardableResult
    func register(_ shortcut: CursorShortcut) -> Bool {
        unregisterHotKey()
        guard installHandlerIfNeeded() else { return false }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        var nextHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &nextHotKeyRef
        )

        guard status == noErr else {
            print("GlobalHotKey: Failed to register \(shortcut.displayName) (\(status))")
            return false
        }

        hotKeyRef = nextHotKeyRef
        print("GlobalHotKey: Registered \(shortcut.displayName)")
        return true
    }

    func unregister() {
        unregisterHotKey()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandlerRef == nil else { return true }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var nextEventHandlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                return hotKey.handle(event: event)
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &nextEventHandlerRef
        )

        guard status == noErr else {
            print("GlobalHotKey: Failed to install event handler (\(status))")
            return false
        }

        eventHandlerRef = nextEventHandlerRef
        return true
    }

    private func handle(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return status }
        guard hotKeyID.signature == signature, hotKeyID.id == identifier else {
            return OSStatus(eventNotHandledErr)
        }

        DispatchQueue.main.async { [action] in
            action()
        }

        return noErr
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

final class KeyboardEventTap {
    private let action: () -> Void
    private var shortcut: CursorShortcut?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        stop()
    }

    @discardableResult
    func start(_ shortcut: CursorShortcut) -> Bool {
        stop()
        self.shortcut = shortcut

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: KeyboardEventTap.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.shortcut = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        print("KeyboardEventTap: Started for \(shortcut.displayName)")
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        shortcut = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<KeyboardEventTap>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let shortcut else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == shortcut.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        guard flags.contains(.maskCommand) == shortcut.modifiers.contains(.command),
            flags.contains(.maskAlternate) == shortcut.modifiers.contains(.option),
            flags.contains(.maskControl) == shortcut.modifiers.contains(.control),
            flags.contains(.maskShift) == shortcut.modifiers.contains(.shift)
        else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [action] in
            action()
        }

        return nil
    }
}

enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func request() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (CursorShortcut) -> Void
    let onCancel: () -> Void
    let onInvalidShortcut: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.onInvalidShortcut = onInvalidShortcut
        nsView.focus()
    }
}

final class ShortcutCaptureNSView: NSView {
    var onCapture: ((CursorShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onInvalidShortcut: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focus()
    }

    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        guard let shortcut = CursorShortcut(event: event) else {
            onInvalidShortcut?()
            return
        }

        onCapture?(shortcut)
    }
}

private extension NSEvent.ModifierFlags {
    static let allowedCursorShortcutFlags: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift,
    ]

    var cursorShortcutFlags: NSEvent.ModifierFlags {
        intersection(Self.allowedCursorShortcutFlags)
    }

    var hasPrimaryShortcutModifier: Bool {
        contains(.command) || contains(.option) || contains(.control)
    }
}
