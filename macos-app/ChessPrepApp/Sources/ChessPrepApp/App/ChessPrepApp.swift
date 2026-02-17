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
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
    }
}
