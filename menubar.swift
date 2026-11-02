// TESDA Worklog: the menu bar app.
//
// Build:  install.sh compiles this into ~/Applications/TESDA Worklog.app (with the octopus icon).
//
// The app does no report logic itself. Every action runs worklog.py (in the same folder)
// in the background, and the app shows the files it writes. It also watches two files in
// the app's data folder:
//   inbox/show.json  - "please show this report": written by the 8 AM job
//   running.json     - a report is being written right now: the icon is dimmed

import AppKit
import WebKit

// MARK: - Paths and running worklog.py

let env = ProcessInfo.processInfo.environment
let appDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let dataDirDefault = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TESDA-Worklog")
/// worklog.py: next to the binary (old layout), else in the app's data folder (app bundle in ~/Applications).
let scriptPath: String = {
    if let s = env["WORKLOG_SCRIPT"] { return s }
    let sibling = appDir.appendingPathComponent("worklog.py").path
    if FileManager.default.fileExists(atPath: sibling) { return sibling }
    let home = env["WORKLOG_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? dataDirDefault
    return home.appendingPathComponent("worklog.py").path
}()
/// launchd starts us at login with --login; opened from the Dock/Finder, we show the report window.
let startedAtLogin = CommandLine.arguments.contains("--login")
let pythonPath = env["WORKLOG_PYTHON"] ?? "/usr/bin/python3"
let appendixMark = "<!-- appendix:"

struct RunResult {
    let status: Int32
    let out: String
    let err: String
    let cancelled: Bool

    /// worklog.py --json prints one JSON object on its last line.
    var json: [String: Any]? {
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return obj
    }
}

final class DataBox { var data = Data() }

final class WorklogRun {
    private let process = Process()
    private(set) var cancelled = false

    init(_ args: [String]) {
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + args
        process.currentDirectoryURL = appDir
        process.standardInput = FileHandle.nullDevice
    }

    /// Runs in the background; `done` is called on the main thread.
    func start(_ done: @escaping (RunResult) -> Void) {
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.collect(outPipe, errPipe)
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Runs and waits. Only for quick commands (projects, resolve, paths).
    func runNow() -> RunResult {
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        return collect(outPipe, errPipe)
    }

    private func collect(_ outPipe: Pipe, _ errPipe: Pipe) -> RunResult {
        do { try process.run() } catch {
            return RunResult(status: -1, out: "", err: "Couldn't start \(pythonPath): \(error.localizedDescription)", cancelled: false)
        }
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errBox.data, as: UTF8.self), cancelled: cancelled)
    }

    /// Sends SIGTERM; worklog.py then stops `claude` and exits.
    func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

struct Paths {
    var dataDir: URL
    var config: URL
    var reportsDir: URL
    var inbox: URL
    var running: URL

    static func load() -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let data = env["WORKLOG_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent("Library/Application Support/TESDA-Worklog")
        var p = Paths(dataDir: data, config: data.appendingPathComponent("config.json"),
                      reportsDir: data.appendingPathComponent("reports"),
                      inbox: data.appendingPathComponent("inbox"), running: data.appendingPathComponent("running.json"))
        if let j = WorklogRun(["paths", "--json"]).runNow().json {
            if let s = j["reports_dir"] as? String { p.reportsDir = URL(fileURLWithPath: s) }
            if let s = j["config"] as? String { p.config = URL(fileURLWithPath: s) }
            if let s = j["inbox"] as? String { p.inbox = URL(fileURLWithPath: s) }
            if let s = j["running"] as? String { p.running = URL(fileURLWithPath: s) }
        }
        return p
    }

    func report(_ day: String, _ ext: String) -> URL { reportsDir.appendingPathComponent("\(day).\(ext)") }

    func meta(_ day: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: report(day, "html").path),
              let data = try? Data(contentsOf: report(day, "json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

let isoDay: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// "Monday, November 2, 2026", or "October 26 – November 10, 2026" for a range key (A_to_B).
func prettyDay(_ day: String) -> String {
    let parts = day.components(separatedBy: "_to_")
    if parts.count == 2, let a = isoDay.date(from: parts[0]), let b = isoDay.date(from: parts[1]) {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.component(.year, from: a) != cal.component(.year, from: b) {
            f.dateFormat = "MMMM d, yyyy"
            return "\(f.string(from: a)) – \(f.string(from: b))"
        }
        f.dateFormat = "MMMM d"
        let left = f.string(from: a)
        f.dateFormat = cal.component(.month, from: a) == cal.component(.month, from: b) ? "d, yyyy" : "MMMM d, yyyy"
        return "\(left) – \(f.string(from: b))"
    }
    return prettyOneDay(day)
}

func prettyOneDay(_ day: String) -> String {
    guard let d = isoDay.date(from: day) else { return day }
    let f = DateFormatter()
    f.dateFormat = "EEEE, MMMM d, yyyy"
    return f.string(from: d)
}

func generatedNote(_ meta: [String: Any]) -> String {
    guard let s = meta["generated_at"] as? String else { return "" }
    let parse = DateFormatter()
    parse.locale = Locale(identifier: "en_US_POSIX")
    parse.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    guard let d = parse.date(from: s) else { return "" }
    let time = DateFormatter()
    time.dateFormat = "HH:mm"
    if Calendar.current.isDateInToday(d) { return "Generated at \(time.string(from: d))" }
    let day = DateFormatter()
    day.dateFormat = "EEE d MMM"
    return "Generated \(day.string(from: d)) at \(time.string(from: d))"
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var paths = Paths.load()
    var reportWindow: ReportWindowController?
    var windowBusy = false
    var timer: Timer?
    var automation: Automation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Already running (e.g. started at login)? Ask that copy to show its window, and quit.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != NSRunningApplication.current }) {
            try? FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
            try? Data(#"{"picker": true}"#.utf8).write(to: paths.inbox.appendingPathComponent("show.json"))
            exit(0)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(nil)
        statusItem.button?.toolTip = "TESDA Worklog"

        let menu = NSMenu()
        menu.addItem(item("Get report now…", #selector(getReportNow), "r"))
        menu.addItem(item("Log something…", #selector(logSomething), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Open reports folder", #selector(openReports), ""))
        menu.addItem(item("Export TESDA history…", #selector(exportArchive), ""))
        menu.addItem(item("Settings (config.json)", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit TESDA Worklog", #selector(quit), "q"))
        statusItem.menu = menu
        buildMainMenu()

        try? FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        if env["WORKLOG_AUTOMATION"] == "1" { automation = Automation(app: self) }
        if !startedAtLogin && Bundle.main.bundleIdentifier != nil { getReportNow() }
    }

    /// Clicking the Dock icon (or opening the app again) shows the report window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        getReportNow()
        return false
    }

    /// In the Dock (with the octopus icon) only while the report window is open.
    func setDockVisible(_ visible: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // bare binary: no icon to show
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// nil = the octopus. A template image: macOS draws it white or black to match the menu bar.
    func setIcon(_ symbol: String?) {
        var img: NSImage? = nil
        if let symbol = symbol {
            img = NSImage(systemSymbolName: symbol, accessibilityDescription: "TESDA Worklog")
        } else if let octopus = Bundle.main.image(forResource: "MenuIcon") {
            octopus.size = NSSize(width: 20, height: 18)
            img = octopus
        } else {
            img = NSImage(systemSymbolName: "list.checklist", accessibilityDescription: "TESDA Worklog")
        }
        if let img = img {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = "TW"
        }
    }

    /// An accessory app has no visible menu bar, but this menu still makes ⌘C/⌘V/⌘W work in its windows.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit TESDA Worklog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    /// Once a second: pick up "show report" requests and dim the icon while any report is being written.
    func tick() {
        let req = paths.inbox.appendingPathComponent("show.json")
        if let data = try? Data(contentsOf: req) {
            try? FileManager.default.removeItem(at: req)   // tells worklog.py we got it
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let day = obj["day"] as? String { window().present(day: day) } else { getReportNow() }
            }
        }
        let alertReq = paths.inbox.appendingPathComponent("alert.json")
        if let data = try? Data(contentsOf: alertReq) {
            try? FileManager.default.removeItem(at: alertReq)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = obj["title"] as? String, let message = obj["message"] as? String,
               Date().timeIntervalSince1970 - (obj["at"] as? Double ?? 0) < 3 * 86400 {   // ignore stale ones
                DispatchQueue.main.async { self.showArchiveAlert(title, message) }
            }
        }
        statusItem.button?.appearsDisabled = windowBusy || externalReportRunning()
        automation?.tick()
    }

    func externalReportRunning() -> Bool {
        guard let data = try? Data(contentsOf: paths.running),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    func window() -> ReportWindowController {
        if reportWindow == nil { reportWindow = ReportWindowController(app: self) }
        return reportWindow!
    }

    @objc func getReportNow() {
        paths = Paths.load()   // config may have changed
        window().presentPicker()
    }

    @objc func logSomething() {
        // Choices: config projects, "General TESDA work", then names typed before (most recent first).
        let info = WorklogRun(["projects", "--log"]).runNow().json ?? [:]
        let choices = info["choices"] as? [String] ?? []
        let last = info["last"] as? String

        guard let (text, name) = LogPanel.ask(choices: choices, preselect: last ?? choices.first ?? "",
                                              automation: automation != nil ? paths.inbox : nil) else { return }
        var args = ["log", text]
        if !name.isEmpty { args.append("--project=\(name)") }
        let r = WorklogRun(args).runNow()
        if r.status == 0 {
            setIcon("checkmark.circle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.setIcon(nil) }
        } else {
            let err = NSAlert()
            err.messageText = "Couldn't save that entry"
            err.informativeText = r.err.isEmpty ? r.out : r.err
            err.runModal()
        }
    }

    @objc func openReports() {
        paths = Paths.load()
        try? FileManager.default.createDirectory(at: paths.reportsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.reportsDir)
    }

    /// "Your TESDA history will be deleted…" from the morning job.
    func showArchiveAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Export a copy…")
        alert.addButton(withTitle: "Get report now…")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: exportArchive()
        case .alertSecondButtonReturn: getReportNow()
        default: break
        }
    }

    /// Zips the TESDA transcript archive into the reports folder and shows it in Finder.
    @objc func exportArchive() {
        WorklogRun(["archive", "export"]).start { r in
            let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status == 0, out.hasPrefix("Exported to ") {
                let url = URL(fileURLWithPath: String(out.dropFirst("Exported to ".count)))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                let a = NSAlert()
                a.messageText = r.status == 0 ? "Nothing to export" : "Couldn't export"
                a.informativeText = r.status == 0 ? out : (r.err.isEmpty ? out : r.err)
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
        }
    }

    @objc func openSettings() {
        _ = WorklogRun(["projects"]).runNow()   // creates config.json if it's missing
        openInEditor(paths.config)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

/// Opens a text file in its default app, or TextEdit if nothing is set up for that file type.
func openInEditor(_ url: URL) {
    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-t", url.path]
    try? p.run()
}

// MARK: - "Log something…" dialog

/// A small centered dialog: app icon, title and description centered, then the entry field,
/// the project box, and Cancel / Log. (NSAlert goes left-aligned once it has extra fields.)
final class LogPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let field = NSTextField()
    let project = NSComboBox()

    private init(choices: [String], preselect: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Log TESDA work")
        title.font = .boldSystemFont(ofSize: 15)
        title.alignment = .center
        let info = NSTextField(wrappingLabelWithString: "Meetings, QA, coordination, documentation: anything you didn't do "
                               + "in Claude Code. Pick a project or type a new one.")
        info.alignment = .center
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor

        field.placeholderString = "e.g. Attended TRACK sprint planning"
        project.addItems(withObjectValues: choices)
        project.completes = true                  // autocompletes names as you type
        project.numberOfVisibleItems = min(max(choices.count, 3), 12)
        project.placeholderString = "Project: pick one or type a new one"
        project.stringValue = preselect

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"           // Esc
        let log = NSButton(title: "Log", target: self, action: #selector(logClicked))
        log.keyEquivalent = "\r"                  // Return
        let buttons = NSStackView(views: [cancel, log])
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, info, field, project, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(16, after: info)
        stack.setCustomSpacing(18, after: project)
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64),
            stack.widthAnchor.constraint(equalToConstant: 400),
        ])
        for v in [info, field, project, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panel.initialFirstResponder = field
    }

    @objc private func cancelClicked() { NSApp.stopModal(withCode: .cancel) }
    @objc private func logClicked() { NSApp.stopModal(withCode: .OK) }
    func windowWillClose(_ notification: Notification) { NSApp.stopModal(withCode: .cancel) }

    /// Layout facts for the automated test (frames in window coordinates).
    private func layoutReport() -> [String: Any] {
        let mid = panel.contentView!.bounds.midX
        var out: [String: Any] = ["windowMidX": Int(mid)]
        for (i, v) in (panel.contentView as! NSStackView).arrangedSubviews.enumerated() {
            let r = v.convert(v.bounds, to: nil)
            out["\(i)"] = ["midX": Int(r.midX), "width": Int(r.width),
                           "align": (v as? NSTextField)?.alignment == .center ? "center" : ""]
        }
        return out
    }

    /// Shows the dialog and waits. Returns (text, project) or nil if cancelled.
    static func ask(choices: [String], preselect: String, automation inbox: URL? = nil) -> (String, String)? {
        let me = LogPanel(choices: choices, preselect: preselect)
        me.panel.center()
        NSApp.activate(ignoringOtherApps: true)
        me.panel.makeKeyAndOrderFront(nil)
        if let inbox = inbox {   // test mode: record the layout, then cancel by itself
            let t = Timer(timeInterval: 1.0, repeats: false) { _ in
                if let d = try? JSONSerialization.data(withJSONObject: me.layoutReport(), options: [.sortedKeys]) {
                    try? d.write(to: inbox.appendingPathComponent("logpanel-layout.json"))
                }
                NSApp.stopModal(withCode: .cancel)
            }
            RunLoop.main.add(t, forMode: .modalPanel)
        }
        let code = NSApp.runModal(for: me.panel)
        me.panel.orderOut(nil)
        guard code == .OK else { return nil }
        let text = me.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, me.project.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Mini range calendar

/// Two months side by side. Click the first day, then the last day; the range is highlighted
/// (and previewed under the mouse between the two clicks). Days after today can't be picked.
final class RangeCalendarView: NSView {
    private(set) var start: Date?
    private(set) var end: Date?
    private(set) var awaitingEnd = false
    private var hover: Date?
    private var month: Date                       // first day of the left-hand month
    var onChange: ((Date, Date, Bool) -> Void)?   // (start, end, finished)

    private let cal = Calendar.current
    private let cw: CGFloat = 32, ch: CGFloat = 28, pad: CGFloat = 14, gap: CGFloat = 28
    private let headerH: CGFloat = 34, weekH: CGFloat = 20, footerH: CGFloat = 30
    private let prevButton = NSButton(), nextButton = NSButton()
    private var today: Date { cal.startOfDay(for: Date()) }
    override var isFlipped: Bool { true }

    init(start: Date?, end: Date?) {
        self.start = start.map { Calendar.current.startOfDay(for: $0) }
        self.end = end.map { Calendar.current.startOfDay(for: $0) }
        let anchor = Calendar.current.startOfDay(for: end ?? Date())
        // Show the end date's month on the right, and the month before it on the left.
        let firstOfEndMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: anchor))!
        month = Calendar.current.date(byAdding: .month, value: -1, to: firstOfEndMonth)!
        super.init(frame: NSRect(x: 0, y: 0, width: pad * 2 + cw * 14 + gap,
                                 height: headerH + weekH + ch * 6 + footerH + pad / 2))
        for (b, sym, sel) in [(prevButton, "chevron.left", #selector(prevMonth)), (nextButton, "chevron.right", #selector(nextMonth))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.target = self
            b.action = sel
            addSubview(b)
        }
        prevButton.frame = NSRect(x: pad - 4, y: 6, width: 24, height: 22)
        nextButton.frame = NSRect(x: bounds.width - pad - 20, y: 6, width: 24, height: 22)
        updateArrows()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func prevMonth() { month = cal.date(byAdding: .month, value: -1, to: month)!; updateArrows(); needsDisplay = true }
    @objc private func nextMonth() { month = cal.date(byAdding: .month, value: 1, to: month)!; updateArrows(); needsDisplay = true }

    private func updateArrows() {
        let right = cal.date(byAdding: .month, value: 1, to: month)!
        nextButton.isEnabled = right < cal.date(from: cal.dateComponents([.year, .month], from: today))!
    }

    // ---- geometry

    private func monthStart(_ i: Int) -> Date { cal.date(byAdding: .month, value: i, to: month)! }
    private func originX(_ i: Int) -> CGFloat { pad + CGFloat(i) * (cw * 7 + gap) }

    /// (date, cell rect) for every day shown.
    private func cells() -> [(Date, NSRect)] {
        var out: [(Date, NSRect)] = []
        for i in 0..<2 {
            let first = monthStart(i)
            let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
            for d in 0..<cal.range(of: .day, in: .month, for: first)!.count {
                let idx = offset + d
                let rect = NSRect(x: originX(i) + CGFloat(idx % 7) * cw, y: headerH + weekH + CGFloat(idx / 7) * ch,
                                  width: cw, height: ch)
                out.append((cal.date(byAdding: .day, value: d, to: first)!, rect))
            }
        }
        return out
    }

    private func day(at p: NSPoint) -> Date? { cells().first(where: { $0.1.contains(p) })?.0 }

    /// The highlighted span: the chosen range, or start→hover while waiting for the second click.
    private func span() -> (Date, Date)? {
        guard let s = start else { return nil }
        let e = awaitingEnd ? (hover ?? s) : (end ?? s)
        return s <= e ? (s, e) : (e, s)
    }

    // ---- drawing

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let center = NSMutableParagraphStyle(); center.alignment = .center
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let titleFmt = DateFormatter(); titleFmt.dateFormat = "MMMM yyyy"
        for i in 0..<2 {
            let x = originX(i)
            (titleFmt.string(from: monthStart(i)) as NSString).draw(
                in: NSRect(x: x, y: 8, width: cw * 7, height: 20),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
                                 .paragraphStyle: center])
            for c in 0..<7 {
                (symbols[(c + cal.firstWeekday - 1) % 7] as NSString).draw(
                    in: NSRect(x: x + CGFloat(c) * cw, y: headerH, width: cw, height: weekH),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                     .paragraphStyle: center])
            }
        }
        let sel = span()
        for (d, r) in cells() {
            var textColor = d > today ? NSColor.tertiaryLabelColor : NSColor.labelColor
            var font = NSFont.systemFont(ofSize: 13)
            if let (lo, hi) = sel, d >= lo, d <= hi {
                let alpha: CGFloat = awaitingEnd ? 0.15 : 0.25
                var band = r.insetBy(dx: 0, dy: 2)
                if lo != hi {
                    if d == lo { band = NSRect(x: r.midX, y: band.minY, width: r.width / 2, height: band.height) }
                    if d == hi { band = NSRect(x: r.minX, y: band.minY, width: r.width / 2, height: band.height) }
                    accent.withAlphaComponent(alpha).setFill()
                    band.fill()
                }
                if d == lo || d == hi {
                    accent.setFill()
                    NSBezierPath(ovalIn: NSRect(x: r.midX - 12, y: r.midY - 12, width: 24, height: 24)).fill()
                    textColor = .white
                    font = .boldSystemFont(ofSize: 13)
                }
            }
            if cal.isDate(d, inSameDayAs: today) && textColor != .white {
                textColor = accent
                font = .boldSystemFont(ofSize: 13)
            }
            ("\(cal.component(.day, from: d))" as NSString).draw(
                in: NSRect(x: r.minX, y: r.midY - 8, width: r.width, height: 18),
                withAttributes: [.font: font, .foregroundColor: textColor, .paragraphStyle: center])
        }
        let hint: String
        if start == nil {
            hint = "Click the first day, then the last day."
        } else if awaitingEnd {
            hint = "Now click the last day."
        } else if let (lo, hi) = sel {
            let n = (cal.dateComponents([.day], from: lo, to: hi).day ?? 0) + 1
            hint = "\(prettyDay(rangeKey(lo, hi))) · \(n) day\(n == 1 ? "" : "s")"
        } else { hint = "" }
        (hint as NSString).draw(in: NSRect(x: pad, y: bounds.height - footerH + 4, width: bounds.width - pad * 2, height: 18),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                                                 .paragraphStyle: center])
    }

    // ---- clicking

    override func mouseDown(with event: NSEvent) {
        if let d = day(at: convert(event.locationInWindow, from: nil)) { click(d) }
    }

    /// First click starts a new range, second click ends it (either order).
    func click(_ date: Date) {
        let d = cal.startOfDay(for: date)
        guard d <= today else { return }
        if start == nil || !awaitingEnd {
            start = d; end = d; awaitingEnd = true
        } else {
            let s = start!
            (start, end) = d < s ? (d, s) : (s, d)
            awaitingEnd = false
        }
        needsDisplay = true
        onChange?(start!, end!, !awaitingEnd)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard awaitingEnd else { return }
        let d = day(at: convert(event.locationInWindow, from: nil))
        if let d = d, d > today { return }
        if d != hover { hover = d; needsDisplay = true }
    }
}

func rangeKey(_ a: Date, _ b: Date) -> String {
    let x = isoDay.string(from: min(a, b)), y = isoDay.string(from: max(a, b))
    return x == y ? x : "\(x)_to_\(y)"
}

// MARK: - Report window ("Get report now")

enum BannerStyle { case info, warning, error }

final class ReportWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    unowned let app: AppDelegate
    let window: NSWindow
    let periodPopup = NSPopUpButton()
    let datePicker = NSDatePicker()          // "Pick a date"
    let rangeButton = NSButton(title: "", target: nil, action: nil)   // "Date range": opens the calendar
    let calendarPopover = NSPopover()
    private(set) var calendarView: RangeCalendarView?
    var rangeStart = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date()))!
    var rangeEnd = Calendar.current.startOfDay(for: Date())
    let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")
    let bannerBox = NSView()
    let bannerLabel = NSTextField(wrappingLabelWithString: "")
    let webView = WKWebView()
    let progressStack = NSStackView()
    let spinner = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "Writing your report…")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let placeholder = NSTextField(wrappingLabelWithString: "")
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let openButton = NSButton(title: "Open file", target: nil, action: nil)
    let regenerateButton = NSButton(title: "Regenerate", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private(set) var currentDay: String?
    private(set) var run: WorklogRun?
    private var runningDay: String?

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "TESDA Worklog"
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TESDAWorklogReport")
        buildUI()
        showPlaceholder("Choose a period and click Generate.")
    }

    // ---- layout

    private func buildUI() {
        periodPopup.addItems(withTitles: ["Today so far", "Previous workday", "Pick a date", "Date range"])
        periodPopup.target = self
        periodPopup.action = #selector(popupChanged)
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.dateValue = Date()
        datePicker.maxDate = Date()
        datePicker.isHidden = true
        datePicker.target = self
        datePicker.action = #selector(periodChanged)
        rangeButton.bezelStyle = .rounded
        rangeButton.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Choose dates")
        rangeButton.imagePosition = .imageLeading
        rangeButton.target = self
        rangeButton.action = #selector(openCalendar)
        calendarPopover.behavior = .transient
        updateRangeTitle()
        generateButton.keyEquivalent = "\r"
        generateButton.bezelStyle = .rounded

        let periodLabel = NSTextField(labelWithString: "Report for:")
        let top = NSStackView(views: [periodLabel, periodPopup, datePicker, rangeButton, NSView(), generateButton])
        top.orientation = .horizontal
        top.spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail

        bannerBox.wantsLayer = true
        bannerBox.layer?.cornerRadius = 6
        bannerBox.layer?.borderWidth = 1
        bannerLabel.isSelectable = true
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerBox.addSubview(bannerLabel)
        NSLayoutConstraint.activate([
            bannerLabel.topAnchor.constraint(equalTo: bannerBox.topAnchor, constant: 8),
            bannerLabel.bottomAnchor.constraint(equalTo: bannerBox.bottomAnchor, constant: -8),
            bannerLabel.leadingAnchor.constraint(equalTo: bannerBox.leadingAnchor, constant: 10),
            bannerLabel.trailingAnchor.constraint(equalTo: bannerBox.trailingAnchor, constant: -10),
        ])
        bannerBox.isHidden = true
        // Long messages must wrap/truncate inside the window, never make the window wider.
        for label in [bannerLabel, statusLabel, placeholder] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        // Content: web view, progress, or a placeholder message, stacked on top of each other.
        let content = NSView()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        spinner.style = .spinning
        spinner.controlSize = .regular
        progressLabel.font = .systemFont(ofSize: 15, weight: .medium)
        let progressHint = NSTextField(labelWithString: "Claude is reading the day's sessions. This can take up to a minute.")
        progressHint.textColor = .secondaryLabelColor
        for v in [spinner, progressLabel, progressHint, cancelButton] { progressStack.addArrangedSubview(v) }
        progressStack.orientation = .vertical
        progressStack.spacing = 12
        progressStack.setCustomSpacing(20, after: progressHint)
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        for v in [webView, progressStack, placeholder] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            progressStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            placeholder.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -60),
        ])
        content.wantsLayer = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.cornerRadius = 6
        content.layer?.masksToBounds = true

        copyButton.toolTip = "Copy the report as plain text, ready to paste into a form. Hold ⌥ Option to copy Markdown instead."
        let bottom = NSStackView(views: [copyButton, openButton, regenerateButton, NSView(), closeButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8

        for (b, sel) in [(generateButton, #selector(generateClicked)), (cancelButton, #selector(cancelClicked)),
                         (copyButton, #selector(copyClicked)), (openButton, #selector(openClicked)),
                         (regenerateButton, #selector(regenerateClicked)), (closeButton, #selector(closeClicked))] {
            b.target = self
            b.action = sel
        }

        let root = NSStackView(views: [top, statusLabel, bannerBox, content, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for v in [top, statusLabel, bannerBox, content, bottom] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        window.contentView = root
        window.center()
        updateButtons()
    }

    // ---- showing the window

    private func bringToFront() {
        app.setDockVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// From the menu: show the picker. Doesn't run anything until you click Generate.
    func presentPicker() {
        if run == nil && currentDay == nil {
            periodPopup.selectItem(at: 0)
            periodChanged()
        }
        bringToFront()
    }

    /// From the 8 AM job: show a finished report.
    func present(day: String) {
        if run == nil {
            select(day: day)
            show(day: day)
        }
        bringToFront()
    }

    private func select(day: String) {
        if day == isoDay.string(from: Date()) {
            periodPopup.selectItem(at: 0)
        } else if day == resolve("prev") {
            periodPopup.selectItem(at: 1)
        } else {
            periodPopup.selectItem(at: 2)
            if let d = isoDay.date(from: day) { datePicker.dateValue = d }
        }
        updatePickers()
    }

    private func updatePickers() {
        let i = periodPopup.indexOfSelectedItem
        datePicker.isHidden = i != 2
        rangeButton.isHidden = i != 3
    }

    func updateRangeTitle() {
        rangeButton.title = " " + prettyDay(rangeKey(rangeStart, rangeEnd)).replacingOccurrences(of: ", \(Calendar.current.component(.year, from: Date()))", with: "")
    }

    @objc func popupChanged() {
        periodChanged()
        if periodPopup.indexOfSelectedItem == 3 { openCalendar() }
    }

    @objc func openCalendar() {
        let cv = RangeCalendarView(start: rangeStart, end: rangeEnd)
        cv.onChange = { [weak self] s, e, finished in
            guard let self = self, finished else { return }
            self.rangeStart = s
            self.rangeEnd = e
            self.updateRangeTitle()
            self.periodChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.calendarPopover.performClose(nil) }
        }
        calendarView = cv
        let vc = NSViewController()
        vc.view = cv
        calendarPopover.contentViewController = vc
        calendarPopover.show(relativeTo: rangeButton.bounds, of: rangeButton, preferredEdge: .maxY)
    }

    private func resolve(_ word: String) -> String? {
        let r = WorklogRun(["resolve", word]).runNow()
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !s.isEmpty ? s : nil
    }

    func selectedDay() -> String? {
        switch periodPopup.indexOfSelectedItem {
        case 0: return isoDay.string(from: Date())
        case 1: return resolve("prev")
        case 2: return isoDay.string(from: datePicker.dateValue)
        default: return rangeKey(rangeStart, rangeEnd)
        }
    }

    // ---- actions

    @objc func periodChanged() {
        updatePickers()
        guard run == nil, let day = selectedDay() else { return }
        if let meta = app.paths.meta(day) {
            statusLabel.stringValue = "\(prettyDay(day)) · a saved report exists (\(generatedNote(meta).lowercased())). Click Generate to view it."
        } else {
            statusLabel.stringValue = "\(prettyDay(day)) · no report yet."
        }
    }

    @objc func generateClicked() {
        guard let day = selectedDay() else { return }
        if app.paths.meta(day) != nil {
            show(day: day)
            if bannerBox.isHidden {   // don't hide a warning about this report (e.g. the AI summary failed)
                setBanner("Showing the report you already generated. Click Regenerate if you want a fresh one.", .info)
            }
        } else {
            start(day: day)
        }
    }

    @objc func regenerateClicked() {
        guard let day = currentDay ?? selectedDay() else { return }
        start(day: day)
    }

    @objc func cancelClicked() { run?.cancel() }

    @objc func copyClicked() {
        guard let day = currentDay else { return }
        let asMarkdown = NSEvent.modifierFlags.contains(.option)
        var text: String?
        if asMarkdown, let md = try? String(contentsOf: app.paths.report(day, "md"), encoding: .utf8) {
            text = md.components(separatedBy: appendixMark).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = try? String(contentsOf: app.paths.report(day, "txt"), encoding: .utf8)
        }
        guard let t = text else { return setBanner("Couldn't read the report file to copy it.", .error) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        copyButton.title = asMarkdown ? "Copied Markdown ✓" : "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.copyButton.title = "Copy" }
    }

    @objc func openClicked() {
        guard let day = currentDay else { return }
        openInEditor(app.paths.report(day, "md"))
    }

    @objc func closeClicked() { window.performClose(nil) }

    // ---- running a report

    func start(day: String) {
        run?.cancel()
        runningDay = day
        hideBanner()
        statusLabel.stringValue = "\(prettyDay(day)) · writing the report…"
        webView.isHidden = true
        placeholder.isHidden = true
        progressStack.isHidden = false
        spinner.startAnimation(nil)
        app.windowBusy = true
        let r = WorklogRun(["report", day.replacingOccurrences(of: "_to_", with: ".."), "--json"])
        run = r
        updateButtons()
        r.start { [weak self] result in self?.finished(day: day, result) }
    }

    private func finished(day: String, _ r: RunResult) {
        run = nil
        runningDay = nil
        app.windowBusy = false
        spinner.stopAnimation(nil)
        progressStack.isHidden = true
        defer { updateButtons() }

        if r.cancelled {
            if app.paths.meta(day) != nil {
                show(day: day)
                setBanner("Cancelled. Showing the version you generated earlier.", .info)
            } else {
                showPlaceholder("Cancelled. Nothing was changed.")
                statusLabel.stringValue = prettyDay(day)
            }
            return
        }
        let json = r.json
        if r.status == 0, json?["ok"] as? Bool == true {
            show(day: day)
            if !window.isVisible { bringToFront() }   // it was closed while running: show the result
            return
        }
        // Something went wrong before a report could be saved.
        var why = (json?["error"] as? String) ?? ""
        if why.isEmpty {
            let lines = (r.err.isEmpty ? r.out : r.err).split(separator: "\n").suffix(6).joined(separator: "\n")
            why = lines.isEmpty ? "worklog.py exited with code \(r.status)." : lines
        }
        setBanner("Couldn't make the report: \(why)", .error)
        if app.paths.meta(day) != nil {
            show(day: day, keepBanner: true)
        } else {
            showPlaceholder("No report was saved. See the message above.")
            statusLabel.stringValue = prettyDay(day)
        }
        if !window.isVisible { bringToFront() }
    }

    func show(day: String, keepBanner: Bool = false) {
        app.paths = Paths.load()
        guard let meta = app.paths.meta(day) else {
            showPlaceholder("No report for \(prettyDay(day)) yet. Click Generate.")
            return
        }
        currentDay = day
        if !keepBanner { hideBanner() }
        var status = "\(prettyDay(day)) · \(generatedNote(meta))"
        if let s = meta["sessions"] as? Int, let m = meta["manual"] as? Int, let k = meta["review"] as? Int {
            let c = meta["commits"] as? Int ?? 0
            status += " · \(s) session\(s == 1 ? "" : "s"), \(m) logged"
                + (c > 0 ? ", \(c) commit\(c == 1 ? "" : "s")" : "") + " · \(k) to review"
        }
        statusLabel.stringValue = status
        if !keepBanner {
            if meta["ai"] as? String == "failed" {
                let err = meta["error"] as? String ?? "unknown error"
                setBanner("The AI summary couldn't be written: \(err)\nThe report below has the raw evidence instead. Fix the problem, then click Regenerate.", .warning)
            } else if let w = meta["warning"] as? String {
                setBanner(w, .warning)
            }
        }
        let html = app.paths.report(day, "html")
        if webView.url == html {
            webView.reloadFromOrigin()
        } else {
            webView.loadFileURL(html, allowingReadAccessTo: app.paths.reportsDir)
        }
        placeholder.isHidden = true
        progressStack.isHidden = true
        webView.isHidden = false
        updateButtons()
    }

    private func showPlaceholder(_ text: String) {
        currentDay = nil
        placeholder.stringValue = text
        placeholder.isHidden = false
        webView.isHidden = true
        progressStack.isHidden = true
        updateButtons()
    }

    private func setBanner(_ text: String, _ style: BannerStyle) {
        let color: NSColor = style == .error ? .systemRed : (style == .warning ? .systemOrange : .systemBlue)
        bannerBox.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        bannerBox.layer?.borderColor = color.withAlphaComponent(0.5).cgColor
        bannerLabel.stringValue = text
        bannerBox.isHidden = false
    }

    private func hideBanner() { bannerBox.isHidden = true }

    private func updateButtons() {
        let busy = run != nil
        let has = currentDay != nil && !busy
        generateButton.isEnabled = !busy
        periodPopup.isEnabled = !busy
        datePicker.isEnabled = !busy
        rangeButton.isEnabled = !busy
        copyButton.isEnabled = has
        openButton.isEnabled = has
        regenerateButton.isEnabled = !busy && (currentDay != nil)
    }

    // ---- window + web view delegates

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }   // a running report keeps going; we reopen when done

    func windowWillClose(_ notification: Notification) { app.setDockVisible(false) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)          // links open in your browser, not in this window
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // ---- for automated testing only (see Automation)

    /// Frames of the main controls in window coordinates (y grows upwards), to sanity-check the layout.
    func layout() -> [String: [Int]] {
        var out: [String: [Int]] = ["window": [0, 0, Int(window.contentView?.bounds.width ?? 0), Int(window.contentView?.bounds.height ?? 0)]]
        let views: [String: NSView] = ["period": periodPopup, "datePicker": datePicker, "rangeButton": rangeButton, "generate": generateButton,
            "status": statusLabel, "banner": bannerBox, "web": webView, "progress": progressStack, "placeholder": placeholder,
            "copy": copyButton, "open": openButton, "regenerate": regenerateButton, "close": closeButton]
        for (name, v) in views where !v.isHidden && v.superview != nil {
            let r = v.convert(v.bounds, to: nil)
            out[name] = [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
        }
        return out
    }

    func uiState() -> [String: Any] {
        [
            "windowVisible": window.isVisible,
            "period": periodPopup.titleOfSelectedItem ?? "",
            "datePickerVisible": !datePicker.isHidden,
            "rangeButton": rangeButton.isHidden ? "" : rangeButton.title,
            "calendarOpen": calendarPopover.isShown,
            "menuIcon": app.statusItem.button?.image?.isTemplate == true ? "image" : (app.statusItem.button?.title ?? ""),
            "status": statusLabel.stringValue,
            "bannerVisible": !bannerBox.isHidden,
            "banner": bannerLabel.stringValue,
            "progressVisible": !progressStack.isHidden,
            "progressText": progressLabel.stringValue,
            "webVisible": !webView.isHidden,
            "webURL": webView.url?.path ?? "",
            "placeholderVisible": !placeholder.isHidden,
            "placeholder": placeholder.stringValue,
            "currentDay": currentDay ?? "",
            "running": run != nil,
            "generateEnabled": generateButton.isEnabled,
            "copyEnabled": copyButton.isEnabled,
            "regenerateEnabled": regenerateButton.isEnabled,
            "copyTitle": copyButton.title,
            "layout": layout(),
        ]
    }
}

// MARK: - Test automation (only when started with WORKLOG_AUTOMATION=1)
//
// Lets a script drive the real buttons, because CI and terminals can't click menu bar apps.
// Write inbox/automation.json like {"cmd":"click","target":"generate"} and read
// inbox/automation-state.json for what the window shows. Never enabled by install.sh.

final class Automation {
    unowned let app: AppDelegate
    init(app: AppDelegate) { self.app = app }

    func tick() {
        let cmdURL = app.paths.inbox.appendingPathComponent("automation.json")
        if let data = try? Data(contentsOf: cmdURL) {
            try? FileManager.default.removeItem(at: cmdURL)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { handle(obj) }
        }
        writeState()
    }

    func handle(_ c: [String: Any]) {
        let w = app.window()
        switch c["cmd"] as? String ?? "" {
        case "menu":
            if c["target"] as? String == "report" { app.getReportNow() }
            if c["target"] as? String == "log" { DispatchQueue.main.async { self.app.logSomething() } }
        case "period":
            w.periodPopup.selectItem(at: c["index"] as? Int ?? 0)
            if let d = c["date"] as? String, let date = isoDay.date(from: d) { w.datePicker.dateValue = date }
            if c["index"] as? Int == 3, let a = (c["date"] as? String).flatMap(isoDay.date(from:)),
               let b = (c["to"] as? String).flatMap(isoDay.date(from:)) {
                w.rangeStart = min(a, b); w.rangeEnd = max(a, b); w.updateRangeTitle()
            }
            w.periodChanged()
        case "click":
            let buttons = ["generate": w.generateButton, "cancel": w.cancelButton, "copy": w.copyButton,
                           "open": w.openButton, "regenerate": w.regenerateButton, "close": w.closeButton]
            buttons[c["target"] as? String ?? ""]?.performClick(nil)
        case "calendar":
            w.periodPopup.selectItem(at: 3)
            w.popupChanged()                                   // same as choosing "Date range"
        case "calendarClick":
            if let d = (c["day"] as? String).flatMap(isoDay.date(from:)) { w.calendarView?.click(d) }
        case "calendarSnapshot":
            if let v = w.calendarView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                let saved = v.appearance
                v.appearance = NSAppearance(named: .aqua)      // snapshot has no popover background
                v.cacheDisplay(in: v.bounds, to: rep)
                v.appearance = saved
                let dir = URL(fileURLWithPath: c["dir"] as? String ?? NSTemporaryDirectory())
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("calendar.png"))
            }
        case "snapshot":
            let dir = URL(fileURLWithPath: c["dir"] as? String ?? NSTemporaryDirectory())
            snapshot(w, to: dir)
        default: break
        }
        writeState()
    }

    func writeState() {
        var s = app.reportWindow?.uiState() ?? [:]
        s["iconDimmed"] = app.statusItem.button?.appearsDisabled ?? false
        s["at"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: app.paths.inbox.appendingPathComponent("automation-state.json"))
        }
    }

    /// The window chrome (web content is drawn out of process, so it's captured separately).
    func snapshot(_ w: ReportWindowController, to dir: URL) {
        if let view = w.window.contentView, let image = NSImage(data: view.dataWithPDF(inside: view.bounds)),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window.png"))
        }
        w.webView.takeSnapshot(with: nil) { image, _ in
            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("web.png"))
            }
        }
    }
}

// MARK: - Start

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
