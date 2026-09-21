import Foundation

struct Window: Codable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Double
    var remaining: Double { max(0, 100 - usedPercent) }
    var duration: Double { Double(windowDurationMins) * 60 }
    var start: Double { resetsAt - duration }
    func projection(at now: Double) -> Double? {
        let elapsed = now - start
        guard elapsed >= 3600, now < resetsAt, duration > 0 else { return nil }
        return usedPercent / elapsed * duration
    }
    func dailyBudget(at now: Double) -> Double? {
        guard resetsAt > now else { return nil }
        return remaining / ((resetsAt - now) / 86400)
    }
}
struct Bucket: Decodable {
    let primary: Window?
    let secondary: Window?
}
struct Limits: Decodable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
    let accountId: String?
    var windows: [Window] {
        let bucket = rateLimitsByLimitId?["codex"] ?? rateLimits
        return [bucket?.primary, bucket?.secondary].compactMap { $0 }
    }
    var weekly: Window? { windows.first { $0.windowDurationMins == 10080 } }
}
struct Sample: Codable {
    let date: Double
    let used: Double
    let reset: Double
}
struct Forecast {
    let cycle: Double?
    let recent: Double?
    var worst: Double? { [cycle, recent].compactMap { $0 }.max() }
    var level: Int { guard let worst else { return 0 }; return worst >= 100 ? 2 : worst >= 90 ? 1 : 0 }
    func runOutAt(for window: Window, now: Double) -> Double? {
        guard window.resetsAt > now, window.remaining > 0,
              let worst, worst.isFinite, worst >= 100, worst > window.usedPercent else { return nil }
        // Both projections start from current usage, so the higher forecast
        // also gives the earliest exhaustion time at a constant pace.
        let rate = (worst - window.usedPercent) / (window.resetsAt - now)
        return now + window.remaining / rate
    }
    static func calculate(_ window: Window, samples: [Sample], now: Double) -> Forecast {
        // Account for backend reset timestamps occasionally differing by one second.
        let candidates = samples.filter { abs($0.reset - window.resetsAt) <= 2 && $0.date >= now - 86400 && $0.date <= now - 21600 && $0.used <= window.usedPercent }.sorted { $0.date < $1.date }
        var recent: Double?
        if let first = candidates.first {
            let spent = window.usedPercent - first.used
            // Whole-percent readings need a meaningful observation interval and change.
            if spent >= 3 { recent = window.usedPercent + spent / (now - first.date) * max(0, window.resetsAt - now) }
        }
        return Forecast(cycle: window.projection(at: now), recent: recent)
    }
}

enum UsageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// Reads only account metadata. Never starts a model turn or accesses auth tokens directly.
final class UsageClient {
    static func fetch() throws -> Limits {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", fm.homeDirectoryForCurrentUser.path + "/.local/bin/codex"]
        guard let executable = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw UsageError.message("Codex CLI was not found. Install Codex and sign in, then refresh.")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = fm.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            // Ensure a stuck child cannot hold a refresh open forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usage_bar", "version": "1.0.0"]]])
        var buffer = Data()
        while true {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw UsageError.message("Usage refresh timed out or Codex disconnected. Check your sign-in and try again.") }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw UsageError.message(error["message"] as? String ?? "Codex could not read usage.")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = object["result"] {
                    return try JSONDecoder().decode(Limits.self, from: JSONSerialization.data(withJSONObject: result))
                }
            }
        }
    }
}

func runTests() {
    let now = 1_000_000.0
    let w = Window(usedPercent: 15, windowDurationMins: 10080, resetsAt: now + 5.7792 * 86400)
    assert(abs(w.projection(at: now)! - 86.01) < 0.1)
    assert(abs(w.dailyBudget(at: now)! - 14.708) < 0.01)
    assert(Forecast.calculate(w, samples: [], now: now).level == 0)
    let fast = Window(usedPercent: 45, windowDurationMins: 10080, resetsAt: now + 5 * 86400)
    assert(Forecast.calculate(fast, samples: [], now: now).level == 2)
    let fastForecast = Forecast.calculate(fast, samples: [], now: now)
    assert(abs(fastForecast.runOutAt(for: fast, now: now)! - (now + 55 / 22.5 * 86400)) < 0.001)
    assert(Forecast.calculate(w, samples: [], now: now).runOutAt(for: w, now: now) == nil)
    let recent = Forecast.calculate(w, samples: [Sample(date: now - 21600, used: 0, reset: w.resetsAt)], now: now)
    assert(recent.level == 2 && recent.recent! > 300)
    assert(abs(recent.runOutAt(for: w, now: now)! - (now + 85 / 15 * 21600)) < 0.001)
    let slowerRecent = Forecast.calculate(fast, samples: [Sample(date: now - 21600, used: 42, reset: fast.resetsAt)], now: now)
    assert(slowerRecent.runOutAt(for: fast, now: now) == fastForecast.runOutAt(for: fast, now: now))
    let atLimit = Window(usedPercent: 50, windowDurationMins: 10080, resetsAt: now + 3.5 * 86400)
    assert(Forecast.calculate(atLimit, samples: [], now: now).runOutAt(for: atLimit, now: now) == atLimit.resetsAt)
    let exhausted = Window(usedPercent: 100, windowDurationMins: 10080, resetsAt: fast.resetsAt)
    assert(Forecast.calculate(exhausted, samples: [], now: now).runOutAt(for: exhausted, now: now) == nil)
    assert(fastForecast.runOutAt(for: fast, now: fast.resetsAt) == nil)
    assert(Forecast.calculate(w, samples: [Sample(date: now - 21600, used: 0, reset: w.resetsAt - 604800)], now: now).recent == nil)
    assert(Forecast.calculate(w, samples: [Sample(date: now - 21600, used: 50, reset: w.resetsAt)], now: now).recent == nil)
    let new = Window(usedPercent: 1, windowDurationMins: 10080, resetsAt: now + 604799)
    assert(new.projection(at: now) == nil)
    assert(Forecast.calculate(new, samples: [], now: now).runOutAt(for: new, now: now) == nil)
    assert(w.projection(at: w.resetsAt) == nil)
    let json = Data(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1000001},"secondary":{"usedPercent":15,"windowDurationMins":10080,"resetsAt":1499322}}}"#.utf8)
    let decoded = try! JSONDecoder().decode(Limits.self, from: json)
    assert(decoded.weekly?.usedPercent == 15 && decoded.windows.count == 2)
    print("PASS: cycle forecast, daily budget, pace warning, run-out estimates, recent trend, reset isolation, decreasing readings, new/expired windows, weekly-window decoding")
}
