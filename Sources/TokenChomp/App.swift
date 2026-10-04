import SwiftUI
import Darwin

@main struct TokenChompApp: App {
    @StateObject private var store = UsageStore()
    init() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--claude-bridge") {
            do { try runClaudeBridge(); exit(0) }
            catch { exit(1) } // Never echo raw status input or provider content.
        }
    }
    var body: some Scene {
        MenuBarExtra {
            Dashboard(store: store)
        } label: {
            // A TimelineView here re-triggers the status item update loop endlessly; the store ticks instead.
            Image(nsImage: Chase.iconImage(used: store.worst, phase: store.iconPhase))
                .accessibilityLabel("TokenChomp: \(store.worst.map { "\(Int(100 - $0)) percent left" } ?? "quota unavailable")")
                .task { store.start() }
        }.menuBarExtraStyle(.window)
    }
}
