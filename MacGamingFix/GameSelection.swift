import AppKit
import Combine

struct ManualGameSelection: Equatable {
    let pid: pid_t
    let displayName: String
    let bundleIdentifier: String?
}

final class RunningAppsObserver: ObservableObject {
    @Published private(set) var apps: [NSRunningApplication] = []

    private var observers: [NSObjectProtocol] = []
    private let workspace = NSWorkspace.shared

    init() {
        refresh()

        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]

        for name in names {
            let token = workspace.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            observers.append(token)
        }
    }

    deinit {
        observers.forEach { workspace.notificationCenter.removeObserver($0) }
    }

    func refresh() {
        let myBundleID = Bundle.main.bundleIdentifier
        apps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != myBundleID }
            .sorted {
                ($0.localizedName ?? "")
                    .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
            }
    }
}
