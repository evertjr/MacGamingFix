import SwiftUI

@main
struct MacGamingFixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            SetupView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.cleanup()
    }
}
