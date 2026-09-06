// AgentUsageBar — a native macOS menu bar app that reproduces Stats' own
// "Mini" widget (Kit/Widgets/Mini.swift in exelban/stats): three separate
// menu-bar boxes, each a small left-aligned caption on top and a bigger
// left-aligned percentage underneath —
//
//    ZAI    Weekly   Claude
//    37%      8%      42%
//
//   ZAI     Z.AI Coding Plan token quota
//   Weekly  Claude weekly (7-day) utilization
//   Claude  5-hour session utilization
//
// It is the macOS menu bar version of agent-usage-widget: same endpoints, same
// severity colors (green < 70, amber 70–89, red ≥ 90), re-built as tiny
// NSStatusItem widgets — no Electron, no dock icon, ~0% idle CPU.
//
// Auth, exactly like the widget:
//   Claude  re-reads ~/.claude/.credentials.json on every poll, then falls
//           back to the macOS Keychain (service "Claude Code-credentials") —
//           current Claude Code builds store the OAuth token there instead of
//           the file, so a Mac with no credentials.json can still be signed
//           in. Falls back further to ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL
//           for relay setups, since some expose the same /api/oauth/usage
//           route.
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
    let label: String         // menu-bar caption: Claude / Weekly / ZAI
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
func claudeFileToken() -> String? {
    guard let raw = try? String(contentsOfFile: claudeCredsPath, encoding: .utf8) else { return nil }
    return parseOAuthAccessToken(raw)
}

/// Newer Claude Code builds keep the OAuth token in the login Keychain
/// (service "Claude Code-credentials") instead of the file — same JSON shape.
/// Shelling out to /usr/bin/security reuses the exact binary a Terminal
/// `security find-generic-password` query already has silent access to, so
/// our own (differently-signed) binary doesn't trigger a fresh Keychain
/// access prompt just to read it.
func claudeKeychainToken() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = Pipe() // silence "security: SecKeychainSearchCopyNext: ..." on a miss
    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let raw = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return parseOAuthAccessToken(raw)
    } catch {
        return nil
    }
}

func parseOAuthAccessToken(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else { return nil }
    return token
}

/// File first (cheap, no subprocess), then Keychain — whichever this
/// particular Mac's Claude Code build actually uses.
func claudeOAuthToken() -> String? {
    claudeFileToken() ?? claudeKeychainToken()
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
///
/// Always returns exactly two rows (session, weekly) — even on failure — so
/// Claude and Weekly each keep their own menu-bar box instead of one collapsing away.
func fetchClaude() async -> [MeterReading] {
    var session = MeterReading(id: "session", label: "Claude", name: "Claude · 5-hour session",
                                percent: nil, resetsAt: nil, error: nil)
    var weekly = MeterReading(id: "claude-weekly", label: "Weekly", name: "Claude · Weekly",
                               percent: nil, resetsAt: nil, error: nil)
    do {
        var url = officialUsageURL
        var viaRelay = false
        let token: String
        if let oauth = claudeOAuthToken() {
            token = oauth
        } else if let relayToken = env("ANTHROPIC_AUTH_TOKEN"), let base = env("ANTHROPIC_BASE_URL") {
            // Relay setup (e.g. the GLM Coding Plan endpoint): some relays proxy
            // the same usage route; if this one doesn't, the rows say so.
            token = relayToken
            viaRelay = true
            url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/oauth/usage")
                ?? officialUsageURL
        } else {
            throw URLError(.userAuthenticationRequired)
        }
        let data = try await fetchJSON(url, headers: claudeUsageHeaders(token: token))
        if let five = data["five_hour"] as? [String: Any],
           let util = five["utilization"] as? Double {
            session.percent = Int(util.rounded())
            session.resetsAt = (five["resets_at"] as? String).flatMap(isoDate)
        }
        if let seven = data["seven_day"] as? [String: Any],
           let util = seven["utilization"] as? Double {
            weekly.percent = Int(util.rounded())
            weekly.resetsAt = (seven["resets_at"] as? String).flatMap(isoDate)
        }
        if session.percent == nil && weekly.percent == nil {
            let msg = viaRelay
                ? "relay doesn't expose /api/oauth/usage — sign in with Claude Code for C/W"
                : "usage response had no session/weekly rows"
            session.error = msg; weekly.error = msg
        }
    } catch {
        let reason: String
        if claudeOAuthToken() == nil && env("ANTHROPIC_AUTH_TOKEN") == nil {
            reason = "not signed in — log in with Claude Code on this Mac"
        } else if let urlErr = error as? URLError, urlErr.code == .userAuthenticationRequired {
            reason = "not signed in — log in with Claude Code on this Mac"
        } else {
            reason = "usage endpoint unreachable (\(error.localizedDescription))"
        }
        session.error = reason; weekly.error = reason
    }
    return [session, weekly]
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
        return MeterReading(id: "zai", label: "ZAI", name: "Z.AI", percent: nil, resetsAt: nil,
                            error: "no key — set ZAI_API_KEY in ~/.config/agent-usage-bar/env")
    }
    do {
        let body = try await fetchJSON(zaiQuotaURL, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ])
        // { code: 200, data: { level, limits: [ { type: "TOKENS_LIMIT", percentage, nextResetTime } ] } }
        if let code = body["code"] as? Int, code != 200 {
            return MeterReading(id: "zai", label: "ZAI", name: "Z.AI", percent: nil, resetsAt: nil,
                                error: body["msg"] as? String ?? "Z.AI error \(code)")
        }
        let data = body["data"] as? [String: Any] ?? [:]
        let limits = data["limits"] as? [[String: Any]] ?? []
        guard let tokens = limits.first(where: { ($0["type"] as? String) == "TOKENS_LIMIT" }) else {
            return MeterReading(id: "zai", label: "ZAI", name: "Z.AI", percent: nil, resetsAt: nil,
                                error: "no TOKENS_LIMIT in response")
        }
        let pct = (tokens["percentage"] as? Double) ?? 0
        let resetMs = tokens["nextResetTime"] as? Double
        return MeterReading(id: "zai", label: "ZAI", name: "Z.AI", percent: Int(pct.rounded()),
                            resetsAt: resetMs.flatMap { Date(timeIntervalSince1970: $0 / 1000) },
                            error: nil)
    } catch {
        return MeterReading(id: "zai", label: "ZAI", name: "Z.AI", percent: nil, resetsAt: nil,
                            error: "quota endpoint unreachable (\(error.localizedDescription))")
    }
}

// MARK: - Formatting

/// Parses both "...371462+00:00" (fractional seconds, what /api/oauth/usage
/// actually returns) and the plain "...+00:00" form — the default
/// ISO8601DateFormatter only handles the latter and silently returns nil on
/// the former, which was making resetsAt (and the reset-time display) always
/// nil for Claude.
func isoDate(_ s: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: s) { return date }
    return ISO8601DateFormatter().date(from: s)
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
    guard let parts = resetsLineParts(date) else { return "" }
    return parts.prefix + parts.countdown
}

/// Same text as `resetsLine`, split into the "resets 22:10 " prefix and the
/// "(50min)" countdown so the menu can highlight the countdown separately —
/// at 13pt secondaryLabelColor it used to read as barely-there.
func resetsLineParts(_ date: Date?) -> (prefix: String, countdown: String)? {
    guard let date else { return nil }
    let cal = Calendar.current
    let sameDay = cal.isDate(date, inSameDayAs: Date())
    let fmt = DateFormatter()
    fmt.dateFormat = sameDay ? "HH:mm" : "EEE HH:mm"
    return ("resets \(fmt.string(from: date)) ", "(\(countdown(to: date)))")
}

// MARK: - Meter widget
//
// A direct port of Stats' own "Mini" widget (Kit/Widgets/Mini.swift in
// exelban/stats) rather than an approximation: same two font sizes (7pt
// label, 12pt value), same left alignment for both lines — Stats does not
// center them, so the shorter line sits flush against the longer line's left
// edge instead of centered under it — and the same non-flipped, bottom-
// anchored rects, just scaled to this bar's own measured content width
// instead of Stats' fixed 31pt (our captions are full words, not letters).

final class MeterColumnView: NSView {
    var reading = MeterReading(id: "", label: "", name: "", percent: nil, resetsAt: nil, error: nil) {
        didSet { needsDisplay = true }
    }

    static let labelFont = NSFont.systemFont(ofSize: 7, weight: .light)
    static let valueFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let leftStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        return style
    }()

    private func labelString() -> NSAttributedString {
        NSAttributedString(string: reading.label.isEmpty ? " " : reading.label, attributes: [
            .font: Self.labelFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Self.leftStyle,
        ])
    }

    private func valueString() -> NSAttributedString {
        let text = reading.percent.map { "\($0)%" } ?? "–"
        let color = reading.percent != nil ? reading.severity.color : NSColor.labelColor
        return NSAttributedString(string: text, attributes: [
            .font: Self.valueFont, .foregroundColor: color, .paragraphStyle: Self.leftStyle,
        ])
    }

    /// Width that fits the wider of the two lines, left edge shared, plus a hair of padding.
    var fittingWidth: CGFloat {
        max(labelString().size().width, valueString().size().width).rounded(.up) + 4
    }

    // Not flipped (AppKit default, same as Stats' Mini widget): y=0 is the
    // bottom. Label sits 10pt down from the top of the bar, value sits 1pt
    // up from the bottom — Stats' own numbers on a 22pt-tall bar, generalized
    // proportionally so a taller (notched-Mac) menu bar still packs the same.
    override func draw(_ dirtyRect: NSRect) {
        let label = labelString(), value = valueString()
        let labelRect = NSRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 7)
        let valueRect = NSRect(x: 0, y: 1, width: bounds.width, height: 13)
        label.draw(with: labelRect)
        value.draw(with: valueRect)
    }
}

// MARK: - Controller

@MainActor
final class BarController: NSObject {
    // One NSStatusItem per meter (Claude, Weekly, ZAI) — separate stacked
    // boxes, the way Stats itself shows one small widget per sensor.
    var items: [NSStatusItem] = []
    var meterViews: [MeterColumnView] = []
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

    // Display order: ZAI, Weekly, Claude (5-hour session) — matches the
    // [zai, weekly, session] order poll() assembles into `readings`.
    static let placeholders: [(label: String, name: String)] = [
        ("ZAI", "Z.AI"), ("Weekly", "Claude · Weekly"), ("Claude", "Claude · 5-hour session"),
    ]

    func start() {
        for (label, name) in Self.placeholders {
            let item = NSStatusBar.system.statusItem(withLength: 30)
            let view = MeterColumnView(frame: NSRect(x: 0, y: 0, width: 30, height: NSStatusBar.system.thickness))
            view.reading = MeterReading(id: "", label: label, name: name, percent: nil, resetsAt: nil, error: nil)
            item.button?.addSubview(view)
            item.button?.toolTip = "Agent Usage Bar"
            items.append(item)
            meterViews.append(view)
        }
        render() // show the placeholders immediately, before the first poll lands
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
            let claude = await fetchClaude() // [session, weekly]
            let zai = await fetchZai()
            // Display order per request: ZAI, Weekly, Claude (5-hour session).
            self.readings = [zai, claude[1], claude[0]]
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

    // MARK: menu bar boxes

    func render() {
        let thickness = NSStatusBar.system.thickness
        for (i, item) in items.enumerated() {
            let view = meterViews[i]
            if i < readings.count { view.reading = readings[i] }
            let width = max(22, view.fittingWidth)
            item.length = width
            view.frame = NSRect(x: 0, y: 0, width: width, height: thickness)
            let r = view.reading
            let value = r.percent.map { "\($0)%" } ?? (r.error ?? "–")
            let reset = resetsLine(r.resetsAt)
            item.button?.toolTip = reset.isEmpty ? "\(r.name): \(value)" : "\(r.name): \(value)  \(reset)"
        }
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
                if let (prefix, countdown) = resetsLineParts(r.resetsAt) {
                    name.append(NSAttributedString(string: "   \(prefix)", attributes: [
                        .font: base, .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                    name.append(NSAttributedString(string: countdown, attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: NSColor.labelColor,
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

        // Same combined menu (all three meters + settings) on every box, so
        // clicking C, W, or Z all opens the full picture.
        for item in items { item.menu = menu }
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
