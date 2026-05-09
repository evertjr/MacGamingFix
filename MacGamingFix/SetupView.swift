import SwiftUI

// MARK: - Feature Card

struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let info: LocalizedStringKey?
    let action: () -> Void

    @State private var bounce = 0
    @State private var showInfo = false

    init(
        icon: String,
        title: String,
        subtitle: String,
        isActive: Bool,
        info: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isActive = isActive
        self.info = info
        self.action = action
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                bounce += 1
                action()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isActive ? .green : .primary)
                        .symbolEffect(.bounce, value: bounce)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))

                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(subtitle)

            if let info {
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About \(title)")
                .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                    Text(info)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 240)
                        .padding()
                }
            }
        }
    }
}

// MARK: - Setup View

struct SetupView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var runningApps = RunningAppsObserver()

    @State private var isRecordingShortcut = false
    @State private var shortcutRecorderMessage = Self.defaultShortcutRecorderMessage
    @State private var didCopyLog = false
    @State private var isPickingGame = false
    @State private var gameSearchQuery = ""
    @FocusState private var isGameSearchFocused: Bool

    private static let defaultShortcutRecorderMessage = "Press a key with Command, Option, or Control."

    var body: some View {
        VStack(spacing: 0) {
            cursorFixCard
            Divider().padding(.horizontal, 8)
            activeGameCard
            Divider().padding(.horizontal, 8)
            cursorShortcutCard
            Divider().padding(.horizontal, 8)
            gameModeCard
            Divider().padding(.horizontal, 8)
            fnKeysCard
            Divider().padding(.horizontal, 8)
            audioFixCard
            Divider().padding(.horizontal, 8)
            diagnosticCard
        }
        .padding(.horizontal, 16)
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(16)
        .frame(width: 320)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            appState.refreshFullscreenShortcutStatus()
        }
    }

    // MARK: - Cursor Fix

    private var cursorFixCard: some View {
        FeatureCard(
            icon: "pointer.arrow.motionlines",
            title: "Cursor Fix",
            subtitle: appState.isActive ? "Active, switch to your game" : "Tap to enable",
            isActive: appState.isActive,
            info: "CrossOver/Wine games share the macOS system cursor. During gameplay, an invisible cursor can drift into the Dock, menu bar, or hot corners, causing macOS to force it visible.\n\nCursor Fix uses a heuristic-based approach to detect and suppress these unwanted system reveals while allowing the game to show the cursor normally in pause menus or inventories."
        ) {
            if appState.isActive {
                appState.deactivate()
            } else {
                appState.activate()
            }
        }
        .accessibilityLabel(appState.isActive ? "Deactivate cursor fix" : "Activate cursor fix")
    }

    // MARK: - Active Game

    private var activeGameCard: some View {
        FeatureCard(
            icon: "scope",
            title: "Active Game",
            subtitle: activeGameSubtitle,
            isActive: appState.manualGameSelection != nil,
            info: "By default, MacGamingFix tracks the frontmost app once your game hides the cursor. If detection misses your game (or picks the wrong one), choose it manually here."
        ) {
            runningApps.refresh()
            gameSearchQuery = ""
            isPickingGame = true
        }
        .popover(isPresented: $isPickingGame, arrowEdge: .trailing) {
            gamePickerPopover
        }
        .onChange(of: isPickingGame) { _, isPresented in
            if !isPresented {
                gameSearchQuery = ""
            }
        }
        .accessibilityLabel("Choose active game")
        .accessibilityValue(activeGameSubtitle)
    }

    private var gamePickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Active Game")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            gameSearchField
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if gameSearchQuery.isEmpty {
                        gamePickerRow(
                            label: "Automatic",
                            symbol: "wand.and.sparkles",
                            appIcon: nil,
                            isSelected: appState.manualGameSelection == nil
                        ) {
                            appState.manualGameSelection = nil
                            isPickingGame = false
                        }

                        Divider()
                            .padding(.horizontal, 14)
                    }

                    let matches = filteredApps

                    if matches.isEmpty {
                        Text(emptyMatchesMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(matches, id: \.processIdentifier) { app in
                            gamePickerRow(
                                label: app.localizedName ?? "Unknown",
                                symbol: nil,
                                appIcon: app.icon,
                                isSelected: appState.manualGameSelection?.pid == app.processIdentifier
                            ) {
                                appState.manualGameSelection = ManualGameSelection(
                                    pid: app.processIdentifier,
                                    displayName: app.localizedName ?? "Unknown",
                                    bundleIdentifier: app.bundleIdentifier
                                )
                                isPickingGame = false
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 260)
    }

    private var gameSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search apps", text: $gameSearchQuery)
                .textFieldStyle(.plain)
                .focused($isGameSearchFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        isGameSearchFocused = true
                    }
                }

            if !gameSearchQuery.isEmpty {
                Button {
                    gameSearchQuery = ""
                    isGameSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: .rect(cornerRadius: 6))
    }

    private var filteredApps: [NSRunningApplication] {
        let query = gameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return runningApps.apps }

        return runningApps.apps.filter { app in
            guard let name = app.localizedName, !name.isEmpty else { return false }
            return name.localizedCaseInsensitiveContains(query)
        }
    }

    private var emptyMatchesMessage: String {
        let query = gameSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "No running apps available"
        }
        return "No matches for \u{201C}\(query)\u{201D}"
    }

    private func gamePickerRow(
        label: String,
        symbol: String?,
        appIcon: NSImage?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.body)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                }

                Text(label)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var activeGameSubtitle: String {
        appState.manualGameSelection?.displayName ?? "Auto-detect"
    }

    // MARK: - Cursor Toggle Shortcut

    private var cursorShortcutCard: some View {
        FeatureCard(
            icon: "command",
            title: "Cursor Toggle",
            subtitle: cursorShortcutSubtitle,
            isActive: isRecordingShortcut,
            info: "Sets a global shortcut that manually shows or hides the cursor while Cursor Fix is active."
        ) {
            shortcutRecorderMessage = Self.defaultShortcutRecorderMessage
            isRecordingShortcut = true
        }
        .popover(isPresented: $isRecordingShortcut, arrowEdge: .trailing) {
            shortcutRecorderPopover
        }
        .accessibilityLabel("Change cursor toggle shortcut")
        .accessibilityValue(cursorShortcutSubtitle)
    }

    private var shortcutRecorderPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(appState.cursorShortcut.displayName, systemImage: "command")
                .font(.title3.weight(.semibold))

            Text(shortcutRecorderMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ShortcutCaptureView(
                onCapture: { shortcut in
                    appState.cursorShortcut = shortcut
                    isRecordingShortcut = false
                },
                onCancel: {
                    isRecordingShortcut = false
                },
                onInvalidShortcut: {
                    shortcutRecorderMessage = "Use a non-Escape key with Command, Option, or Control."
                }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)

            Divider()

            fullscreenSupportSection

            HStack {
                Button("Reset") {
                    appState.resetCursorShortcut()
                    isRecordingShortcut = false
                }

                Spacer()

                Button("Cancel") {
                    isRecordingShortcut = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var fullscreenSupportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(
                    systemName: appState.cursorShortcutFullscreenSupported
                        ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(appState.cursorShortcutFullscreenSupported ? .green : .orange)
                .font(.caption)

                Text(
                    appState.cursorShortcutFullscreenSupported
                        ? "Fullscreen support enabled"
                        : "Fullscreen games need Accessibility access"
                )
                .font(.caption.weight(.semibold))
            }

            if !appState.cursorShortcutFullscreenSupported {
                Text(
                    "True-fullscreen games bypass Carbon hot keys. Granting Accessibility lets MacGamingFix listen at the input layer so the shortcut works inside any game."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    appState.requestFullscreenShortcutPermission()
                } label: {
                    Label("Open Accessibility settings", systemImage: "lock.shield")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Game Mode

    private var gameModeCard: some View {
        FeatureCard(
            icon: "gamecontroller.fill",
            title: "Game Mode",
            subtitle: gameModeSubtitle,
            isActive: appState.gameModeEnabled && appState.isGameModeAvailable,
            info: "Uses macOS Game Mode to reduce Bluetooth audio and input latency, and prioritize your game's CPU and GPU usage.\n\nRequires Xcode Command Line Tools. If not installed, tapping this card will prompt the installation."
        ) {
            if appState.isGameModeAvailable {
                appState.gameModeEnabled.toggle()
            } else {
                appState.installXcodeTools()
            }
        }
    }

    // MARK: - Function Keys

    private var fnKeysCard: some View {
        FeatureCard(
            icon: "keyboard",
            title: "Standard F-Keys",
            subtitle: appState.fnKeysEnabled ? "F1–F12 act as function keys" : "Using default media keys",
            isActive: appState.fnKeysEnabled,
            info: "Temporarily switches Apple keyboards so F1–F12 send standard function keys instead of media controls (brightness, volume, etc.).\n\nThis change is not saved — your keyboard reverts to its normal behavior when you toggle this off or quit the app."
        ) {
            appState.fnKeysEnabled.toggle()
        }
    }

    // MARK: - Audio Fix

    private var audioFixCard: some View {
        FeatureCard(
            icon: "waveform",
            title: "Audio 44.1 kHz",
            subtitle: appState.audioFixEnabled ? "Output set to 44,100 Hz" : "Using default sample rate",
            isActive: appState.audioFixEnabled,
            info: "Temporarily switches the default audio output to 44,100 Hz, which fixes crackling or missing sound in some CrossOver/Wine games.\n\nYour original sample rate is restored when you toggle this off or quit the app."
        ) {
            appState.audioFixEnabled.toggle()
        }
    }

    private var diagnosticCard: some View {
        HStack(spacing: 0) {
            FeatureCard(
                icon: "waveform.badge.magnifyingglass",
                title: "Diagnostics",
                subtitle: appState.isLogging ? "Recording trace..." : "Tap to start recording",
                isActive: appState.isLogging,
                info: "Records a detailed trace of cursor hide/show decisions. Start recording, reproduce the issue, then come back and copy the log to your clipboard to share in a bug report."
            ) {
                appState.toggleLogging()
                didCopyLog = false
            }

            if appState.isLogging || didCopyLog {
                Button {
                    appState.copyLogToClipboard()
                    didCopyLog = true
                } label: {
                    Image(systemName: didCopyLog ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(didCopyLog ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy log to clipboard")
            }
        }
    }

    private var gameModeSubtitle: String {
        if !appState.isGameModeAvailable {
            return "Requires Command Line Tools"
        }
        return appState.gameModeEnabled ? "Reduces latency" : "Disabled"
    }

    private var cursorShortcutSubtitle: String {
        if appState.cursorShortcutRegistrationFailed {
            return "\(appState.cursorShortcut.displayName) unavailable"
        }

        if !appState.cursorShortcutFullscreenSupported {
            return "\(appState.cursorShortcut.displayName) — windowed only"
        }

        return appState.cursorShortcut.displayName
    }
}
