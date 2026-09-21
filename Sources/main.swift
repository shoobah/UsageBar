import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement

final class UsageStore: ObservableObject {
    @Published var limits: Limits?
    @Published var updated: Date?
    @Published var error: String?
    @Published var refreshing = false
    @Published var notifications = UserDefaults.standard.bool(forKey: "notifications")
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    var samples: [Sample] = []
    var onChange: (() -> Void)?
    var timer: Timer?
    private var account: String?
    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UsageBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    var weekly: Window? { limits?.weekly }
    var stale: Bool { error != nil || updated.map { Date().timeIntervalSince($0) > 180 } ?? true }
    var forecast: Forecast? {
        weekly.map { Forecast.calculate($0, samples: samples, now: Date().timeIntervalSince1970) }
    }
    var expired: Bool { weekly.map { $0.resetsAt <= Date().timeIntervalSince1970 } ?? false }
    var level: Int { stale || expired ? 0 : (weekly?.remaining == 0 ? 2 : forecast?.level ?? 0) }
    var headline: String {
        if error != nil { return "Refresh unavailable" }
        if limits == nil { return "Connecting to Codex…" }
        if weekly == nil { return "No weekly limit reported" }
        if expired { return "Waiting for the new allowance" }
        if weekly?.remaining == 0 { return "Weekly allowance exhausted" }
        if forecast?.worst == nil { return "Learning your pace" }
        return level == 2 ? "Your pace is too high" : level == 1 ? "Getting close to your limit" : "On track for your reset"
    }
    func start() {
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([Sample].self, from: data) { samples = saved }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try UsageClient.fetch() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let limits):
                    if let old = self.account, let new = limits.accountId, old != new { self.samples = [] }
                    self.account = limits.accountId
                    self.limits = limits
                    self.updated = Date()
                    self.error = nil
                    if let w = limits.weekly {
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
        guard notifications, level == 2, let w = weekly else { return }
        let key = "lastWarning"
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: key) >= 21600 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your Codex usage pace is too high"
        content.body = "\(Int(w.remaining))% remaining. At this pace, you may run out before your weekly reset."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pace-warning", content: content, trigger: nil)) { error in
            if error == nil { UserDefaults.standard.set(now, forKey: key) }
        }
    }
    func setNotifications(_ enabled: Bool) {
        if !enabled { notifications = false; UserDefaults.standard.set(false, forKey: "notifications"); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.notifications = granted
                UserDefaults.standard.set(granted, forKey: "notifications")
                if granted { self.warnIfNeeded() }
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

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    var panelHeight: CGFloat = 440
    var tint: Color { store.stale ? .secondary : store.level == 2 ? .red : store.level == 1 ? .orange : .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    allowance
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
            Text("CODEX").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
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
                    Spacer()
                    Text("100% limit")
                }.font(.caption).foregroundStyle(.secondary)
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
        let windows = store.limits?.windows.filter { $0.windowDurationMins != 10080 } ?? []
        return ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
            row("\(w.windowDurationMins / 60)-hour allowance", "\(Int(w.remaining))% remaining")
        }
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Notify me when my pace is too high", isOn: Binding(get: { store.notifications }, set: store.setNotifications)).toggleStyle(.checkbox)
            Toggle("Launch at login", isOn: Binding(get: { store.loginEnabled }, set: store.setLogin)).toggleStyle(.checkbox)
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
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh now · automatically refreshes every minute").disabled(store.refreshing)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }.buttonStyle(.borderless)
    }
    func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium).monospacedDigit() }.font(.callout)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = UsageStore()
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsagePanel(store: store))
        store.onChange = { [weak self] in self?.updateStatus() }
        updateStatus()
        store.start()
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
        button.toolTip = "Codex weekly allowance remaining · \(store.headline)"
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            let availableHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 600
            let height = min(440, max(160, availableHeight - 32))
            let controller = NSHostingController(rootView: UsagePanel(store: store, panelHeight: height))
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
    do {
        let limits = try UsageClient.fetch()
        if let w = limits.weekly {
            print("LIVE OK: \(Int(w.usedPercent))% used, \(Int(w.remaining))% remaining; reset \(Date(timeIntervalSince1970: w.resetsAt))")
        } else { print("LIVE OK: no weekly window reported") }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
