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

            if let info {
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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

    var body: some View {
        VStack(spacing: 0) {
            cursorFixCard
            Divider().padding(.horizontal, 8)
            gameModeCard
        }
        .padding(.horizontal, 16)
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(16)
        .frame(width: 320)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
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

    private var gameModeSubtitle: String {
        if !appState.isGameModeAvailable {
            return "Requires Command Line Tools"
        }
        return appState.gameModeEnabled ? "Reduces latency" : "Disabled"
    }
}
