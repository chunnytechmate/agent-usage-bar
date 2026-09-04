// AgentUsageBar — a native macOS menu bar app (the "Stats" style) that shows
// three agent-quota percentages, nothing else:
//
//     C 42% · W 8% · Z 37%
//
//   C  Claude 5-hour session utilization
//   W  Claude weekly (7-day) utilization
//   Z  Z.AI Coding Plan token quota
//
// It is the macOS menu bar version of agent-usage-widget: same endpoints, same
// severity colors (green < 70, amber 70–89, red ≥ 90), re-built as a tiny
// NSStatusItem app — no Electron, no dock icon, ~0% idle CPU.
//
// Auth, exactly like the widget:
//   Claude  re-reads ~/.claude/.credentials.json on every poll (Claude Code
//           keeps that token refreshed). Falls back to ANTHROPIC_AUTH_TOKEN +
//           ANTHROPIC_BASE_URL for relay setups, since some expose the same
//           /api/oauth/usage route.
//   Z.AI    ZAI_API_KEY env → ~/.config/agent-usage-bar/env → the original
//           widget's .env → ANTHROPIC_AUTH_TOKEN when the base URL is z.ai
//           (the GLM Coding Plan key works against the quota endpoint).

import AppKit
import Foundation
import ServiceManagement

// MARK: - Model

enum Severity: String {
    case normal, warning, critical

    var color: NSColor {
        switch self {
        case .normal:   return NSColor(srgbRed: 0.298, green: 0.686, blue: 0.490, alpha: 1) // #4caf7d
        case .warning:  return NSColor(srgbRed: 0.878, green: 0.639, blue: 0.149, alpha: 1) // #e0a326
        case .critical: return NSColor(srgbRed: 0.878, green: 0.322, blue: 0.290, alpha: 1) // #e0524a
        }
    }

    static func of(_ pct: Double) -> Severity {
        if pct >= 90 { return .critical }
        if pct >= 70 { return .warning }
        return .normal
    }
}

struct MeterReading {
    let id: String            // "session" | "claude-weekly" | "zai"
    let label: String         // menu-bar letter: C / W / Z
    let name: String          // full name for the menu rows
    var percent: Int?
    var resetsAt: Date?
    var error: String?

    var severity: Severity { percent.map { Severity.of(Double($0)) } ?? .normal }
}

// MARK: - Providers

let claudeCredsPath = NSHomeDirectory() + "/.claude/.credentials.json"
let officialUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let zaiQuotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

func env(_ name: String) -> String? {
    guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// ~/.claude/.credentials.json → { claudeAiOauth: { accessToken } }, re-read
/// every poll so we always ride the token Claude Code itself keeps fresh.
func claudeOAuthToken() -> String? {
    guard let raw = try? String(contentsOfFile: claudeCredsPath, encoding: .utf8),
          let data = raw.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    return token
}

func fetchJSON(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "GET"
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw URLError(.badServerResponse)
    }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw URLError(.cannotParseResponse)
    }
    return obj
}

func claudeUsageHeaders(token: String) -> [String: String] {
    [
        "Authorization": "Bearer \(token)",
        "anthropic-beta": "oauth-2025-04-20",
        "anthropic-version": "2023-06-01",
        "Accept": "application/json",
        "User-Agent": "agent-usage-bar/0.1.0",
    ]
}

/// Claude session + weekly rows. Prefers a real Claude Code OAuth login; falls
/// back to the ANTHROPIC_* relay environment when one is configured.
func fetchClaude() async -> [MeterReading] {
    do {
        var url = officialUsageURL
        var viaRelay = false
        var token: String
        if let oauth = claudeOAuthToken() {
            token = oauth
        } else if let relayToken = env("ANTHROPIC_AUTH_TOKEN"), let base = env("ANTHROPIC_BASE_URL") {
            // Relay setup (e.g. the GLM Coding Plan endpoint): some relays proxy
            // the same usage route; if this one doesn't, the row says so.
            token = relayToken
            viaRelay = true
            url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/oauth/usage")
                ?? officialUsageURL
        } else {
            throw URLError(.userAuthenticationRequired)
        }
        let data = try await fetchJSON(url, headers: claudeUsageHeaders(token: token))
        var rows: [MeterReading] = []
        if let five = data["five_hour"] as? [String: Any],
           let util = five["utilization"] as? Double {
            rows.append(MeterReading(id: "session", label: "C", name: "Claude · 5-hour session",
                                     percent: Int(util.rounded()),
                                     resetsAt: (five["resets_at"] as? String).flatMap(isoDate),
                                     error: nil))
        }
        if let seven = data["seven_day"] as? [String: Any],
           let util = seven["utilization"] as? Double {
            rows.append(MeterReading(id: "claude-weekly", label: "W", name: "Claude · Weekly",
                                     percent: Int(util.rounded()),
                                     resetsAt: (seven["resets_at"] as? String).flatMap(isoDate),
                                     error: nil))
        }
        if rows.isEmpty {
            return [MeterReading(id: "claude", label: "C", name: "Claude", percent: nil, resetsAt: nil,
                                 error: viaRelay
                                     ? "relay doesn't expose /api/oauth/usage — sign in with Claude Code for C/W"
                                     : "usage response had no session/weekly rows")]
        }
        return rows
    } catch {
        let reason: String
        if claudeOAuthToken() == nil && env("ANTHROPIC_AUTH_TOKEN") == nil {
            reason = "not signed in — log in with Claude Code on this Mac"
        } else if let urlErr = error as? URLError, urlErr.code == .userAuthenticationRequired {
            reason = "not signed in — log in with Claude Code on this Mac"
        } else {
            reason = "usage endpoint unreachable (\(error.localizedDescription))"
        }
        return [MeterReading(id: "claude", label: "C", name: "Claude", percent: nil, resetsAt: nil, error: reason)]
    }
}

/// First non-empty ZAI_API_KEY from: env → the bar's own env file → the
/// original widget's .env → the ANTHROPIC relay token when it points at z.ai.
func zaiKey() -> String? {
    if let k = env("ZAI_API_KEY") { return k }
    let home = NSHomeDirectory()
    for path in ["\(home)/.config/agent-usage-bar/env",
                 "\(home)/projects/agent-usage-widget/.env"] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        if let m = rangeOfFirstMatch(in: raw, pattern: #"(?m)^\s*ZAI_API_KEY\s*=\s*["']?([^"'\s]+)"?"#) {
            let v = String(raw[m]).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
    }
    // A GLM Coding Plan relay token is the same key the quota endpoint wants.
    if let token = env("ANTHROPIC_AUTH_TOKEN"), let base = env("ANTHROPIC_BASE_URL"), base.contains("z.ai") {
        return token
    }
    return nil
}

func rangeOfFirstMatch(in text: String, pattern: String) -> Range<String.Index>? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
    return r
}

func fetchZai() async -> MeterReading {
    guard let key = zaiKey() else {
        return MeterReading(id: "zai", label: "Z", name: "Z.AI", percent: nil, resetsAt: nil,
                            error: "no key — set ZAI_API_KEY in ~/.config/agent-usage-bar/env")
    }
    do {
        let body = try await fetchJSON(zaiQuotaURL, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ])
        // { code: 200, data: { level, limits: [ { type: "TOKENS_LIMIT", percentage, nextResetTime } ] } }
        if let code = body["code"] as? Int, code != 200 {
            return MeterReading(id: "zai", label: "Z", name: "Z.AI", percent: nil, resetsAt: nil,
                                error: body["msg"] as? String ?? "Z.AI error \(code)")
        }
        let data = body["data"] as? [String: Any] ?? [:]
        let limits = data["limits"] as? [[String: Any]] ?? []
        guard let tokens = limits.first(where: { ($0["type"] as? String) == "TOKENS_LIMIT" }) else {
            return MeterReading(id: "zai", label: "Z", name: "Z.AI", percent: nil, resetsAt: nil,
                                error: "no TOKENS_LIMIT in response")
        }
        let pct = (tokens["percentage"] as? Double) ?? 0
        let resetMs = tokens["nextResetTime"] as? Double
        return MeterReading(id: "zai", label: "Z", name: "Z.AI", percent: Int(pct.rounded()),
                            resetsAt: resetMs.flatMap { Date(timeIntervalSince1970: $0 / 1000) },
                            error: nil)
    } catch {
        return MeterReading(id: "zai", label: "Z", name: "Z.AI", percent: nil, resetsAt: nil,
                            error: "quota endpoint unreachable (\(error.localizedDescription))")
    }
}

// MARK: - Formatting

func isoDate(_ s: String) -> Date? {
    ISO8601DateFormatter().date(from: s)
}

/// "50min" / "2h 05m" / "4d 19h" — the widget's countdown style.
func countdown(to target: Date) -> String {
    let secs = max(0, Int(target.timeIntervalSinceNow))
    let h = secs / 3600, m = (secs % 3600) / 60, d = h / 24
    if d >= 1 { return "\(d)d \(h % 24)h" }
    if h >= 1 { return "\(h)h \(String(format: "%02d", m))m" }
    return "\(m)min"
}

/// "resets 22:10 (50min)" today, "resets Thu 08:59 (4d 19h)" another day.
func resetsLine(_ date: Date?) -> String {
    guard let date else { return "" }
    let cal = Calendar.current
    let sameDay = cal.isDate(date, inSameDayAs: Date())
    let fmt = DateFormatter()
    fmt.dateFormat = sameDay ? "HH:mm" : "EEE HH:mm"
    return "resets \(fmt.string(from: date)) (\(countdown(to: date)))"
}

// MARK: - Controller

@MainActor
final class BarController: NSObject {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    var readings: [MeterReading] = []
    var updatedAt = Date()

    static let intervals: [(label: String, seconds: Int)] = [
        ("1 min", 60), ("5 min", 300), ("15 min", 900), ("30 min", 1800),
    ]

    var intervalSeconds: Int {
        get { UserDefaults.standard.object(forKey: "pollIntervalSeconds") as? Int ?? 300 }
        set {
            UserDefaults.standard.set(newValue, forKey: "pollIntervalSeconds")
            scheduleTimer()
        }
    }

    func start() {
        statusItem.button?.toolTip = "Agent Usage Bar"
        rebuildMenu()
        poll()
        scheduleTimer()
        // Re-poll shortly after wake, like Stats does — sleep makes countdowns
        // and meters stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self?.poll()
            }
        }
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll() {
        Task { @MainActor in
            let claude = await fetchClaude()
            let zai = await fetchZai()
            self.readings = claude + [zai]
            self.updatedAt = Date()
            self.render()
            self.rebuildMenu()
            // One line per poll so `make run` users (and we) can see what the
            // bar knows without opening the menu (stderr: unbuffered).
            let line = readings.map { r -> String in
                if let pct = r.percent { return "\(r.label)=\(pct)%" }
                return "\(r.label)=–(\(r.error ?? "n/a"))"
            }.joined(separator: " ")
            FileHandle.standardError.write(Data("[\(self.timeOnly(self.updatedAt))] \(line)\n".utf8))
        }
    }

    // MARK: menu bar title

    func render() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString()
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let dim = NSColor.labelColor.withAlphaComponent(0.55)

        for (i, r) in readings.enumerated() {
            if i > 0 { title.append(str("  ·  ", font: labelFont, color: dim)) }
            title.append(str(" \(r.label) ", font: labelFont, color: dim))
            if let pct = r.percent {
                title.append(str("\(pct)%", font: valueFont, color: r.severity.color))
            } else {
                title.append(str("–", font: valueFont, color: dim))
            }
        }
        if readings.isEmpty {
            title.append(str("…", font: valueFont, color: dim))
        }
        button.attributedTitle = title
        button.toolTip = readings.map { r -> String in
            let value = r.percent.map { "\($0)%" } ?? (r.error ?? "–")
            return "\(r.name): \(value)"
        }.joined(separator: "\n")
    }

    func str(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    // MARK: menu

    func rebuildMenu() {
        let menu = NSMenu()

        for r in readings {
            let item = NSMenuItem()
            item.isEnabled = false
            let line = NSMutableAttributedString()
            let base = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let name = NSMutableAttributedString(
                string: r.name,
                attributes: [.font: base, .foregroundColor: NSColor.labelColor])
            if let pct = r.percent {
                let sev = NSAttributedString(string: "  \(pct)%", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: r.severity.color,
                ])
                name.append(sev)
                let reset = resetsLine(r.resetsAt)
                if !reset.isEmpty {
                    name.append(NSAttributedString(string: "   \(reset)", attributes: [
                        .font: base, .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                line.append(name)
            } else if let err = r.error {
                name.append(NSAttributedString(string: "   \(err)", attributes: [
                    .font: NSFont(
                        descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor
                            .withSymbolicTraits(.italic),
                        size: 12) ?? NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                line.append(name)
            }
            item.attributedTitle = line
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(pollAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let intervalMenu = NSMenu(title: "Poll Interval")
        for (label, seconds) in Self.intervals {
            let item = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = seconds == intervalSeconds ? .on : .off
            intervalMenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "Poll Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        if isBundledApp {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            login.isEnabled = false
            login.title = "Launch at Login  (run the .app to enable)"
        }
        menu.addItem(login)

        menu.addItem(.separator())

        let updated = NSMenuItem(title: "Updated \(timeOnly(updatedAt))", action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)

        let quit = NSMenuItem(title: "Quit Agent Usage Bar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func timeOnly(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: d)
    }

    @objc func pollAction() { poll() }

    @objc func setInterval(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Int { intervalSeconds = seconds }
        rebuildMenu()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(message: "Could not change login item: \(error.localizedDescription)").runModal()
        }
        rebuildMenu()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

extension NSAlert {
    convenience init(message: String) {
        self.init()
        self.messageText = message
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only: no dock icon, no focus steal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let bar = BarController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        bar.start()
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
