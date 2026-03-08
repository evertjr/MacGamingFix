import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            statusBanner

            VStack(alignment: .leading, spacing: 20) {
                Spacer()

                activateSection
                gameModeSection

                Spacer()
            }
            .padding(24)
        }
        .frame(width: 400, height: 340)
    }

    // MARK: - Status Banner

    @ViewBuilder
    private var statusBanner: some View {
        if appState.isActive {
            let gameModeText = appState.gameModeEnabled && appState.isGameModeAvailable
                ? " + Game Mode"
                : ""

            HStack {
                Image(systemName: "gamecontroller.fill")
                Text("Active — Cursor fence enabled\(gameModeText)")
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.green.opacity(0.15))
            .foregroundStyle(.green)
        }
    }

    // MARK: - Activate

    private var activateSection: some View {
        VStack(spacing: 12) {
            Text("Activate, then play. The game process is detected automatically when it first hides the cursor.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                if appState.isActive {
                    appState.deactivate()
                } else {
                    appState.activate()
                }
            } label: {
                Text(appState.isActive ? "Deactivate" : "Activate")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    // MARK: - Game Mode

    private var gameModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.isGameModeAvailable {
                Toggle("Enable Game Mode", isOn: $appState.gameModeEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(appState.isActive)

                Text("Reduces Bluetooth latency and improves CPU scheduling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Install Xcode Command Line Tools to enable Game Mode (reduces Bluetooth latency, improves performance).")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Install Command Line Tools") {
                    appState.installXcodeTools()
                }
            }
        }
    }
}
