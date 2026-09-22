import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

/// Shared settings and the provider shown in the menu bar.
final class AppModel: ObservableObject {
    let stores: [UsageStore]
    @Published var selected: Provider { didSet { UserDefaults.standard.set(selected.rawValue, forKey: "provider"); onChange?() } }
    @Published var notifications = UserDefaults.standard.bool(forKey: "notifications")
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    var onChange: (() -> Void)?
    var current: UsageStore { stores.first { $0.provider == selected } ?? stores[0] }
    init() {
        let available = Provider.allCases.filter(\.isAvailable)
        // Without any sign-in, show Codex so its setup message explains what is missing.
        let stores = (available.isEmpty ? [.codex] : available).map { UsageStore(provider: $0) }
        let saved = UserDefaults.standard.string(forKey: "provider").flatMap(Provider.init)
        self.stores = stores
        selected = saved.flatMap { p in stores.contains { $0.provider == p } ? p : nil } ?? stores[0].provider
    }
    func setNotifications(_ enabled: Bool) {
        if !enabled { notifications = false; UserDefaults.standard.set(false, forKey: "notifications"); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.notifications = granted
                UserDefaults.standard.set(granted, forKey: "notifications")
                if granted { self.stores.forEach { $0.warnIfNeeded() } }
                else {
                    let alert = NSAlert()
                    alert.messageText = "Notifications are disabled"
                    alert.informativeText = "Allow UsageBar notifications in System Settings → Notifications to receive pace alerts. Menu bar warnings remain active."
                    alert.runModal()
                }
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

final class UsageStore: ObservableObject {
    let provider: Provider
    @Published var usage: Usage?
    @Published var updated: Date?
    @Published var error: String?
    @Published var refreshing = false
    @Published var showingUsageInfo = false
    @Published var explainingUsage = false
    @Published var usageExplanation: String?
    @Published var usageExplanationError: String?
    var samples: [Sample] = []
    var onChange: (() -> Void)?
    var timer: Timer?
    private var account: String?
    private var lastAttempt: Date?
    private let historyURL: URL
    init(provider: Provider) {
        self.provider = provider
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UsageBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        historyURL = dir.appendingPathComponent(provider == .codex ? "history.json" : "history-\(provider.rawValue).json")
    }
    var weekly: Window? { usage?.weekly }
    var stale: Bool { error != nil || updated.map { Date().timeIntervalSince($0) > provider.refreshInterval * 3 } ?? true }
    var forecast: Forecast? {
        weekly.map { Forecast.calculate($0, samples: samples, now: Date().timeIntervalSince1970) }
    }
    var expired: Bool { weekly.map { $0.resetsAt <= Date().timeIntervalSince1970 } ?? false }
    var level: Int { stale || expired ? 0 : (weekly?.remaining == 0 ? 2 : forecast?.level ?? 0) }
    var estimatedRunOut: String? {
        guard !stale, let window = weekly else { return nil }
        let now = Date().timeIntervalSince1970
        let forecast = Forecast.calculate(window, samples: samples, now: now)
        guard let timestamp = forecast.runOutAt(for: window, now: now) else { return nil }
        return Date(timeIntervalSince1970: timestamp).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
    var headline: String {
        if error != nil { return "Refresh unavailable" }
        if usage == nil { return "Connecting to \(provider.name)…" }
        if weekly == nil { return "No weekly limit reported" }
        if expired { return "Waiting for the new allowance" }
        if weekly?.remaining == 0 { return "Weekly allowance exhausted" }
        if forecast?.worst == nil { return "Learning your pace" }
        return level == 2 ? "Your pace is too high" : level == 1 ? "Getting close to your limit" : "On track for your reset"
    }
    func start() {
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([Sample].self, from: data) { samples = saved }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh(force: false) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    func refresh(force: Bool = true) {
        guard !refreshing else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < provider.refreshInterval - 5 { return }
        refreshing = true
        lastAttempt = Date()
        let provider = provider
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try provider.fetch() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let usage):
                    if let old = self.account, let new = usage.accountId, old != new { self.samples = [] }
                    self.account = usage.accountId
                    self.usage = usage
                    self.updated = Date()
                    self.error = nil
                    if let w = usage.weekly {
                        let now = Date().timeIntervalSince1970
                        self.samples = self.samples.filter { abs($0.reset - w.resetsAt) <= 2 && $0.date > now - 86400 * 2 }
                        if let last = self.samples.last, w.usedPercent < last.used { self.samples = [] }
                        if self.samples.last.map({ now - $0.date >= 300 }) ?? true {
                            self.samples.append(Sample(date: now, used: w.usedPercent, reset: w.resetsAt))
                            if let data = try? JSONEncoder().encode(self.samples) { try? data.write(to: self.historyURL, options: .atomic) }
                        }
                    }
                    self.warnIfNeeded()
                case .failure(let error): self.error = error.localizedDescription
                }
                self.onChange?()
            }
        }
    }
    func warnIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "notifications"), level == 2, let w = weekly else { return }
        let key = provider == .codex ? "lastWarning" : "lastWarning-\(provider.rawValue)"
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: key) >= 21600 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your \(provider.name) usage pace is too high"
        content.body = "\(Int(w.remaining))% remaining. At this pace, you may run out before your weekly reset."
        if let estimate = estimatedRunOut {
            content.body = "\(Int(w.remaining))% remaining. Estimated to run out \(estimate) at this pace (local time)."
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pace-warning-\(provider.rawValue)", content: content, trigger: nil)) { error in
            if error == nil { UserDefaults.standard.set(now, forKey: key) }
        }
    }
    func explainUsage() {
        guard !explainingUsage else { return }
        explainingUsage = true
        usageExplanation = nil
        usageExplanationError = nil
        let since = weekly?.start ?? Date().addingTimeInterval(-86400).timeIntervalSince1970
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try UsageExplanationClient.generate(since: since) }
            DispatchQueue.main.async {
                self.explainingUsage = false
                switch result {
                case .success(let explanation): self.usageExplanation = explanation
                case .failure(let error): self.usageExplanationError = error.localizedDescription
                }
            }
        }
    }
}

struct ProviderPanel: View {
    @ObservedObject var model: AppModel
    var panelHeight: CGFloat = 440
    var body: some View { UsagePanel(store: model.current, model: model, panelHeight: panelHeight) }
}

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var model: AppModel
    var panelHeight: CGFloat = 440
    var tint: Color { store.stale ? .secondary : store.level == 2 ? .red : store.level == 1 ? .orange : .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    allowance
                    dailyRemaining
                    pace
                    resetInfo
                    otherWindows
                    DisclosureGroup("Settings & forecast details") {
                        VStack(alignment: .leading, spacing: 12) {
                            settings
                            Text("Forecast uses your average since reset. Recent pace appears after 6 hours of observations and a 3-point change. Amber: ≥90% projected; red: ≥100%. Estimates, not guarantees.")
                                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 8)
                    }.font(.callout)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }.padding(16).frame(width: 380, height: panelHeight)
    }
    var header: some View {
        HStack {
            Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.secondary)
            Text("UsageBar").font(.title3.weight(.semibold))
            Spacer()
            if model.stores.count > 1 {
                Picker("Provider", selection: $model.selected) {
                    ForEach(model.stores.map(\.provider)) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            } else {
                Text(store.provider.name.uppercased()).font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder var allowance: some View {
        if let w = store.weekly {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int(w.remaining))%").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(store.expired ? "previous allowance" : "remaining").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: min(100, max(0, w.usedPercent)), total: 100).tint(tint)
                HStack {
                    Text("\(Int(w.usedPercent))% used this week")
                    Button { store.showingUsageInfo.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What affects usage?")
                    .help("What affects usage?")
                    .popover(isPresented: Binding(get: { store.showingUsageInfo }, set: { store.showingUsageInfo = $0 }), arrowEdge: .bottom) {
                        usageInfo
                    }
                    Spacer()
                    Text("100% limit")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    var usageInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What affects usage?", systemImage: "info.circle.fill")
                .font(.headline)
            Text("Usage varies with task complexity, model, reasoning effort, and how long a task runs.")
            Text("\(store.provider.name) reports the total allowance used, but does not identify which individual task caused it.")
                .foregroundStyle(.secondary)
            if store.provider == .codex { activityExplanation }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 330, alignment: .leading)
    }
    @ViewBuilder var activityExplanation: some View {
            Divider()
            if store.explainingUsage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing recent local activity…")
                }
            } else if let explanation = store.usageExplanation {
                Text("Likely local contributors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(explanation)
                    .textSelection(.enabled)
                Button("Analyze again") { store.explainUsage() }
            } else {
                if let error = store.usageExplanationError {
                    Text(error).foregroundStyle(.red)
                }
                Button("Analyze recent activity") { store.explainUsage() }
            }
            Text("On demand only. Sends short task descriptions and token totals to an ephemeral, low-reasoning Codex run. The analysis itself uses additional allowance.")
                .font(.caption2).foregroundStyle(.secondary)
    }
    @ViewBuilder var dailyRemaining: some View {
        if let window = store.weekly {
            VStack(alignment: .leading, spacing: 6) {
                if !store.stale, let estimate = DailyEstimate.calculate(window, samples: store.samples, now: Date().timeIntervalSince1970) {
                    row("Remaining today (estimated)", String(format: "%.1f%%", estimate.remaining))
                    Text("Of weekly limit · Usage tracked since \(Date(timeIntervalSince1970: estimate.observedSince).formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    row("Remaining today (estimated)", "—")
                    Text("Waiting for a fresh usage reading.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    var statusSymbol: String {
        if store.stale { return "wifi.exclamationmark" }
        if store.level == 2 { return "exclamationmark.triangle.fill" }
        if store.level == 1 { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }
    var pace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.headline, systemImage: statusSymbol).font(.headline).foregroundStyle(tint)
            if let estimate = store.estimatedRunOut {
                Text("Estimated to run out \(estimate) at this pace.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            forecastRows
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder var forecastRows: some View {
        if !store.expired, let f = store.forecast, let cycle = f.cycle {
            row("Projected use at reset", "\(Int(cycle.rounded()))%")
            if let recent = f.recent { row("At your recent pace", "\(Int(recent.rounded()))%") }
            if let budget = store.weekly?.dailyBudget(at: Date().timeIntervalSince1970) {
                row("Available per day", String(format: "%.1f%% of weekly limit", budget))
            }
        }
    }
    @ViewBuilder var resetInfo: some View {
        if let w = store.weekly {
            VStack(alignment: .leading, spacing: 6) {
                row("Next reset", Date(timeIntervalSince1970: w.resetsAt).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                Text("Your local time · " + (TimeZone.current.abbreviation() ?? "")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
    var otherWindows: some View {
        let windows = store.usage?.windows.filter { $0.label != nil || $0.windowDurationMins != 10080 } ?? []
        return ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
            let name = (w.label ?? "\(w.windowDurationMins / 60)-hour") + " allowance"
            let reset = Date(timeIntervalSince1970: w.resetsAt)
            VStack(alignment: .leading, spacing: 6) {
                row(name, "\(Int(w.remaining))% remaining")
                Text("\(name) · Resets \(w.windowDurationMins > 1440 ? reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : reset.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Notify me when my pace is too high", isOn: Binding(get: { model.notifications }, set: model.setNotifications)).toggleStyle(.checkbox)
            Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin)).toggleStyle(.checkbox)
        }.font(.callout)
    }
    var footer: some View {
        HStack {
            if store.refreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
            } else if let date = store.updated {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(store.stale ? Color.orange : Color.secondary)
            }
            Spacer()
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh now · automatically refreshes every \(store.provider.refreshInterval > 60 ? "\(Int(store.provider.refreshInterval / 60)) minutes" : "minute")").disabled(store.refreshing)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }.buttonStyle(.borderless)
    }
    func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium).monospacedDigit() }.font(.callout)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    var store: UsageStore { model.current }
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ProviderPanel(model: model))
        model.onChange = { [weak self] in self?.updateStatus() }
        for store in model.stores {
            store.onChange = { [weak self] in self?.updateStatus() }
            store.start()
        }
        updateStatus()
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() } }
    }
    func updateStatus() {
        guard let button = item.button else { return }
        let symbol = store.stale ? "questionmark.circle" : store.level == 2 ? "exclamationmark.triangle.fill" : store.level == 1 ? "exclamationmark.circle.fill" : "chart.bar.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: store.headline)
        if store.level > 0 {
            let color: NSColor = store.level == 2 ? .systemRed : .systemOrange
            let warningImage = image?.withSymbolConfiguration(.init(paletteColors: [color]))
            warningImage?.isTemplate = false
            button.image = warningImage
        } else {
            // Normal and unavailable readings follow the menu bar's background contrast.
            image?.isTemplate = true
            button.image = image
        }
        button.imagePosition = .imageLeading
        button.contentTintColor = nil
        button.title = store.weekly.map { " \(Int($0.remaining))%" + (store.stale || store.expired ? " ·" : "") } ?? " —"
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = "\(store.provider.name) weekly allowance remaining · \(store.headline)"
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            let availableHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 600
            let height = min(440, max(160, availableHeight - 32))
            let controller = NSHostingController(rootView: ProviderPanel(model: model, panelHeight: height))
            controller.sizingOptions = []
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: 380, height: height)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}

if CommandLine.arguments.contains("--self-test") { runTests() }
else if CommandLine.arguments.contains("--probe") {
    let requested = Provider.allCases.filter { CommandLine.arguments.contains($0.rawValue) }
    var failed = false
    for provider in requested.isEmpty ? Provider.allCases.filter(\.isAvailable) : requested {
        do {
            let usage = try provider.fetch()
            if let w = usage.weekly {
                print("\(provider.name) LIVE OK: \(Int(w.usedPercent))% used, \(Int(w.remaining))% remaining; reset \(Date(timeIntervalSince1970: w.resetsAt))")
            } else { print("\(provider.name) LIVE OK: no weekly window reported") }
        } catch { fputs("\(provider.name): \(error.localizedDescription)\n", stderr); failed = true }
    }
    if failed { exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
