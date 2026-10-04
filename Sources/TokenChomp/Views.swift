import SwiftUI
import ChompCore

struct Dashboard: View {
    @ObservedObject var store: UsageStore
    var compact = false
    private struct Source { let name: String; let tint: Color; let quotas: [Quota]; let error: String? }
    private var sources: [Source] {
        var list: [Source] = []
        if store.codexEnabled { list.append(Source(name: "Codex", tint: .mint, quotas: store.displayedCodex, error: store.demo ? nil : store.codexError)) }
        if store.claudeEnabled { list.append(Source(name: "Claude", tint: .orange, quotas: store.displayedClaude, error: store.demo ? nil : store.claudeError)) }
        return list
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            if compact { widgetRows } else { header; ForEach(sources, id: \.name) { card($0) } }
            if sources.isEmpty { Text("Enable a provider in Connections.").font(.caption).foregroundStyle(.secondary) }
            if !compact {
                Divider()
                HStack {
                    Text("Ghost at 70% · close chase at 90%").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
                }
                DisclosureGroup("Connections & options") { options.padding(.top, 10) }.font(.caption)
            }
        }
        .padding(compact ? 12 : 16)
        .frame(width: compact ? 300 : 360)
    }
    private var header: some View {
        HStack {
            Text("TokenChomp").font(.system(.title3, design: .rounded, weight: .bold))
            Spacer()
            if store.demo { Text("DEMO").font(.caption2.bold()).foregroundStyle(.orange) }
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(store.refreshing || store.demo).help("Refresh quota")
        }
    }
    /// Widget: one line per window, no chrome. Most-used window per provider unless every window is requested.
    private var widgetRows: some View {
        ForEach(sources, id: \.name) { source in
            let shown = store.widgetShowsAll ? source.quotas : Array(source.quotas.sorted { $0.used > $1.used }.prefix(1))
            if shown.isEmpty {
                Text("\(source.name): \(source.error ?? "waiting for quota")").font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(shown) { quota in
                    QuotaRow(quota: quota, animated: store.animations, failed: source.error != nil, prefix: source.name, tint: source.tint)
                }
            }
        }
    }
    private func card(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(source.tint).frame(width: 6, height: 6)
                Text(source.name.uppercased()).font(.caption.bold()).tracking(1.5)
                Spacer()
                if store.refreshing && source.name == "Codex" { ProgressView().controlSize(.mini) }
            }
            if source.quotas.isEmpty {
                Text(source.error ?? "Waiting for quota…").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(source.quotas) { QuotaRow(quota: $0, animated: store.animations, failed: source.error != nil) }
                if let error = source.error { Text(error).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Codex", isOn: $store.codexEnabled).onChange(of: store.codexEnabled) { _ in store.refresh() }
            TextField("Absolute path to codex", text: $store.codexPath).textFieldStyle(.roundedBorder)
            Toggle("Claude Code", isOn: $store.claudeEnabled).onChange(of: store.claudeEnabled) { _ in store.refresh() }
            Toggle("Per-model limits (Fable…) from Claude Code's usage cache", isOn: $store.claudeModelLimits)
                .onChange(of: store.claudeModelLimits) { _ in store.refresh() }
            Button("Copy Claude bridge configuration") {
                let path = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
                let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' --claude-bridge"
                // refreshInterval keeps the bridge fed while a session sits idle; 5 min spares the battery.
                let object: [String: Any] = ["statusLine": ["type": "command", "command": quoted, "refreshInterval": 300]]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Text("Merge the copied statusLine into ~/.claude/settings.json, then start Claude Code. This replaces an existing status line; keep a backup. The app never edits that file.").font(.caption2).foregroundStyle(.secondary)
            Toggle("Start at login", isOn: $store.launchAtLogin)
            Toggle("Animate characters", isOn: $store.animations)
            Toggle("Demo mode · sample data", isOn: $store.demo).onChange(of: store.demo) { value in if !value { store.refresh() } }
            if store.demo {
                Slider(value: $store.demoUsed, in: 0...100)
                Text("\(Int(store.demoUsed))% used · drag to watch the ghost approach").font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Widget lists every window (Session, Weekly, per-model)", isOn: $store.widgetShowsAll)
            Button("Show desktop widget") { WidgetController.shared.show(store: store) }
        }.toggleStyle(.checkbox)
    }
}

/// One line: [provider dot] title · rail · percent left. Reset and observation times live in the tooltip.
struct QuotaRow: View {
    let quota: Quota
    let animated: Bool
    let failed: Bool
    var prefix: String? = nil
    var tint: Color? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let stale = failed || quota.isStale(at: timeline.date)
            HStack(spacing: 8) {
                if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
                VStack(alignment: .leading, spacing: 0) {
                    Text([prefix, quota.title].compactMap { $0 }.joined(separator: " "))
                        .font(.caption).lineLimit(1).truncationMode(.tail)
                    Text(caption(now: timeline.date, stale: stale))
                        .font(.caption2).foregroundStyle(stale ? Color.orange : Color.secondary).lineLimit(1)
                }
                .frame(width: prefix == nil ? 92 : 118, alignment: .leading)
                Chase(used: quota.used, animated: animated && !stale).frame(height: 24)
                Text(stale ? "Stale" : quota.used >= 100 ? "Limit" : "\(Int(quota.remaining.rounded()))%")
                    .font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(stale ? Color.orange : Color.primary)
                    .frame(width: 42, alignment: .trailing)
            }
            .help("\(quota.title) · \(Int(quota.used))% used · \(resetText(now: timeline.date)) · observed \(quota.observedAt.formatted(date: .omitted, time: .shortened))"
                  + (quota.hasGhost && !stale ? " · ghost closing in" : ""))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(prefix ?? "") \(quota.title): \(Int(quota.remaining.rounded())) percent left, \(resetText(now: timeline.date))\(stale ? ", stale" : "")")
        }
    }
    /// Why a reading is stale matters: a passed reset is not the same as a silent provider.
    private func caption(now: Date, stale: Bool) -> String {
        if let reset = quota.resetsAt, reset <= now { return "reset due · awaiting update" }
        if stale { return failed ? "refresh failed" : "no update · \(age(now: now)) old" }
        if quota.id.hasPrefix("model:"), now.timeIntervalSince(quota.observedAt) > 900 { return "\(age(now: now)) old · " + shortReset(now: now) }
        return shortReset(now: now)
    }
    private func age(now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(quota.observedAt) / 60))
        return minutes >= 1440 ? "\(minutes / 1440)d" : minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }
    private func shortReset(now: Date) -> String {
        guard let reset = quota.resetsAt else { return "no reset time" }
        let minutes = Int(ceil(reset.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "reset due" }
        if minutes >= 1440 { return "resets \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "resets \(minutes / 60)h \(minutes % 60)m" }
        return "resets \(minutes)m"
    }
    private func resetText(now: Date) -> String {
        guard let reset = quota.resetsAt else { return "Reset not reported" }
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "Reset due · awaiting update" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}

@MainActor final class WidgetController: NSObject, NSWindowDelegate {
    static let shared = WidgetController()
    private var panel: NSPanel?
    func show(store: UsageStore) {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 300, height: 230),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "TokenChomp"; panel.isFloatingPanel = true; panel.level = .normal
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Dashboard(store: store, compact: true))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.delegate = self; panel.setFrameAutosaveName("TokenChompWidget")
        self.panel = panel; panel.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { panel = nil }
}
