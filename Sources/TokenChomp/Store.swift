import SwiftUI
import ServiceManagement
import ChompCore

@MainActor final class UsageStore: ObservableObject {
    @Published var codex: [Quota] = []
    @Published var claude: [Quota] = []
    @Published var codexError: String?
    @Published var claudeError: String?
    /// Direct-poll trouble shown under the Claude card without flagging bridge rows as failed.
    @Published var claudeNote: String?
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
    @Published var claudeDirect = (UserDefaults.standard.object(forKey: "claudeDirect") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(claudeDirect, forKey: "claudeDirect")
            directQuotas = []; claudeNote = nil; directSuspended = false; lastClaudePoll = .distantPast
        }
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
    /// Direct Claude polls run on their own cadence inside the minute tick: 5 min on mains, 15 on battery.
    /// Not at all while the Mac or its displays sleep; the wake notification polls once immediately.
    private var directQuotas: [Quota] = []
    private var lastClaudePoll = Date.distantPast
    private var systemAsleep = false, screensAsleep = false
    /// A denied Keychain prompt stops scheduled polls; the toggle or the refresh button retries.
    private var directSuspended = false
    var claudePollInterval: TimeInterval { PowerState.conserving ? 15 * 60 : 5 * 60 }
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
        let center = NSWorkspace.shared.notificationCenter
        let sleepEvents: [(Notification.Name, Bool, Bool)] = [
            (NSWorkspace.willSleepNotification, true, true), (NSWorkspace.didWakeNotification, true, false),
            (NSWorkspace.screensDidSleepNotification, false, true), (NSWorkspace.screensDidWakeNotification, false, false)]
        for (name, system, sleeping) in sleepEvents {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let store = self else { return }
                Task { @MainActor in
                    if system { store.systemAsleep = sleeping } else { store.screensAsleep = sleeping }
                    // Waking polls once as soon as both gates clear; a busy refresh leaves it for the next tick.
                    if !sleeping, !store.systemAsleep, !store.screensAsleep { store.lastClaudePoll = .distantPast; store.refresh() }
                }
            }
        }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let store = self else { return }
            Task { @MainActor in
                guard store.iconCanAnimate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                store.iconPhase = Date().timeIntervalSinceReferenceDate
            }
        }
    }
    func refresh(manual: Bool = false) {
        guard !refreshing, !demo else { return }
        if manual { directSuspended = false; lastClaudePoll = .distantPast }
        refreshing = true
        let path = codexPath, enabled = codexEnabled
        Task {
            // Claude is independent: a slow Codex refresh cannot delay it.
            if claudeEnabled {
                let interval = claudePollInterval
                if claudeDirect, !directSuspended, !systemAsleep, !screensAsleep,
                   Date().timeIntervalSince(lastClaudePoll) >= interval {
                    lastClaudePoll = Date() // Set before the call so a failing endpoint is not hammered every minute.
                    do {
                        let fresh = try await ClaudeUsageProvider.collect(maxAge: interval * 2 + 60)
                        if claudeDirect { directQuotas = fresh; claudeNote = nil } // The toggle may have flipped meanwhile.
                    } catch {
                        if claudeDirect { claudeNote = error.localizedDescription }
                        if error is KeychainDenied { directSuspended = true }
                    }
                }
                // Freshness follows the current cadence, so switching to battery does not strand a healthy reading.
                for i in directQuotas.indices { directQuotas[i].maxAge = interval * 2 + 60 }
                let models = claudeModelLimits ? ((try? LocalState.readClaudeSnapshot()) ?? []) : []
                let bridge = (try? LocalState.readClaude()) ?? []
                let keepModels = !models.isEmpty || !directQuotas.isEmpty
                var merged = bridge.filter { !$0.id.hasPrefix("model:") || keepModels }
                for q in directQuotas + models {
                    if let i = merged.firstIndex(where: { $0.id == q.id }) {
                        if merged[i].observedAt < q.observedAt { merged[i] = q }
                    } else { merged.append(q) }
                }
                claude = merged
                claudeError = !claude.isEmpty ? nil
                    : claudeDirect ? (claudeNote ?? "Waiting for Claude usage.")
                    : "Connect the Claude status-line bridge below, then start a session."
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
