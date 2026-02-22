import AppKit
import SwiftUI

@main
struct ChessPrepApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootSplitView(state: state)
                .frame(minWidth: 1180, minHeight: 760)
                .background(Theme.background.ignoresSafeArea())
                .preferredColorScheme(.light)
                .tint(Theme.accent)
                .onAppear {
                    configureAppAppearance()
                    TelemetryService.shared.startSession()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    TelemetryService.shared.endSession()
                }
        }
        .windowStyle(.titleBar)
    }

    private func configureAppAppearance() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
              let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }

        NSApp.applicationIconImage = iconImage
    }
}
