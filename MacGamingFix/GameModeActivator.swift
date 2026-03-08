import Foundation

class GameModeActivator {
    private var isActive = false
    private(set) var isAvailable = false

    init() {
        isAvailable = checkAvailability()
    }

    func sync(enabled: Bool) {
        guard isAvailable else { return }

        if enabled {
            // Avoid duplicate calls while already active.
            if isActive { return }
            isActive = setGameMode(to: "on")
            return
        }

        // Always force "auto" when disabled so the toggle is authoritative.
        _ = setGameMode(to: "auto")
        isActive = false
    }

    func deactivate() {
        sync(enabled: false)
    }

    private func checkAvailability() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", "gamepolicyctl"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func setGameMode(to value: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["gamepolicyctl", "game-mode", "set", value]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func promptInstallXcodeTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    static func xcodeToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
