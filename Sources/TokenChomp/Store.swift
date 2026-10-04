import SwiftUI
import ServiceManagement
import ChompCore

@MainActor final class UsageStore: ObservableObject {
    @Published var codex: [Quota] = []
    @Published var claude: [Quota] = []
    @Published var codexError: String?
    @Published var claudeError: String?
    @Published var refreshing = false
    @Published var demo = false
    @Published var demoUsed = 82.0
    @Published var codexPath = UserDefaults.standard.string(forKey: "codexPath") ?? CodexProvider.defaultExecutable {
        didSet { UserDefaults.standard.set(codexPath, forKey: "codexPath") }
    }
    @Published var codexEnabled = (UserDefaults.standard.object(forKey: "codexEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(codexEnabled, forKey: "codexEnabled") }
    }
    @Published var claudeEnabled = (UserDefaults.standard.object(forKey: "claudeEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(claudeEnabled, forKey: "claudeEnabled") }
    }
    @Published var claudeModelLimits = (UserDefaults.standard.object(forKey: "claudeModelLimits") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(claudeModelLimits, forKey: "claudeModelLimits") }
    }
    @Published var widgetShowsAll = (UserDefaults.standard.object(forKey: "widgetShowsAll") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(widgetShowsAll, forKey: "widgetShowsAll") }
    }
    @Published var animations = (UserDefaults.standard.object(forKey: "animations") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(animations, forKey: "animations") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }
    /// Menu-bar animation clock: advances only while the icon may animate, so a still icon costs nothing.
    @Published private(set) var iconPhase = 0.0
    private var timer: Timer?
    private var iconTimer: Timer?
    var displayedCodex: [Quota] { demo ? samples(used: demoUsed) : codex }
    var displayedClaude: [Quota] { demo ? samples(used: max(0, demoUsed - 16)) : claude }
    var worst: Double? {
        let all = (codexEnabled ? displayedCodex : []) + (claudeEnabled ? displayedClaude : [])
        return all.map(\.used).max()
    }
    var iconCanAnimate: Bool {
        guard animations else { return false }
        if demo { return true }
        let active = (codexEnabled ? codex : []) + (claudeEnabled ? claude : [])
        return !active.isEmpty && !active.contains { $0.isStale() }
            && !(codexEnabled && codexError != nil) && !(claudeEnabled && claudeError != nil)
    }
    private func samples(used: Double) -> [Quota] {
        [Quota(id: "primary", title: "5-hour", used: used, resetsAt: Date().addingTimeInterval(7200)),
         Quota(id: "secondary", title: "7-day", used: used * 0.7, resetsAt: Date().addingTimeInterval(172800))]
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        // Unwrap before the Task: older Swift (5.10) rejects a captured weak var inside it.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let store = self else { return }
            Task { @MainActor in store.refresh() }
        }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let store = self else { return }
            Task { @MainActor in
                guard store.iconCanAnimate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                store.iconPhase = Date().timeIntervalSinceReferenceDate
            }
        }
    }
    func refresh() {
        guard !refreshing, !demo else { return }
        refreshing = true
        let path = codexPath, enabled = codexEnabled
        Task {
            // Claude is independent: a slow Codex refresh cannot delay it.
            if claudeEnabled {
                let models = claudeModelLimits ? ((try? LocalState.readClaudeSnapshot()) ?? []) : []
                do {
                    let q = try LocalState.readClaude().filter { !$0.id.hasPrefix("model:") || !models.isEmpty }
                    claude = q + models.filter { m in !q.contains { $0.id == m.id } }
                    claudeError = claude.isEmpty ? "Waiting for Claude Code quota." : nil
                } catch {
                    claude = models
                    claudeError = "Connect the Claude status-line bridge below, then start a session."
                }
            }
            if enabled {
                let result = await Task.detached { () -> Result<[Quota], Error> in
                    Result { try CodexProvider.collect(executable: path) }
                }.value
                switch result {
                case .success(let q): codex = q; codexError = nil
                case .failure(let error): codexError = error.localizedDescription
                }
            }
            refreshing = false
        }
    }
}
