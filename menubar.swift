// TESDA Worklog: the menu bar app.
//
// Build:  swiftc -O menubar.swift -o TESDAWorklog      (install.sh does this for you)
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
let scriptPath = env["WORKLOG_SCRIPT"] ?? appDir.appendingPathComponent("worklog.py").path
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

func prettyDay(_ day: String) -> String {
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("list.checklist")
        statusItem.button?.toolTip = "TESDA Worklog"

        let menu = NSMenu()
        menu.addItem(item("Get report now…", #selector(getReportNow), "r"))
        menu.addItem(item("Log something…", #selector(logSomething), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Open reports folder", #selector(openReports), ""))
        menu.addItem(item("Settings (config.json)", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit TESDA Worklog", #selector(quit), "q"))
        statusItem.menu = menu
        buildMainMenu()

        try? FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        if env["WORKLOG_AUTOMATION"] == "1" { automation = Automation(app: self) }
    }

    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func setIcon(_ symbol: String) {
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "TESDA Worklog") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
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
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let day = obj["day"] as? String {
                window().present(day: day)
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
        let projects = WorklogRun(["projects"]).runNow().out
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        let alert = NSAlert()
        alert.messageText = "Log TESDA work"
        alert.informativeText = "Meetings, QA, coordination, documentation: anything you didn't do in Claude Code."
        let field = NSTextField(frame: NSRect(x: 0, y: 34, width: 360, height: 24))
        field.placeholderString = "e.g. Attended TRACK sprint planning with the regional office"
        let popup = NSPopUpButton(frame: NSRect(x: -2, y: 0, width: 364, height: 26))
        popup.addItems(withTitles: projects.isEmpty ? ["(add projects to config.json)"] : projects)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        box.addSubview(field)
        box.addSubview(popup)
        alert.accessoryView = box
        alert.addButton(withTitle: "Log")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var args = ["log", text]
        if !projects.isEmpty, let p = popup.titleOfSelectedItem { args.append("--project=\(p)") }
        let r = WorklogRun(args).runNow()
        if r.status == 0 {
            setIcon("checkmark.circle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.setIcon("list.checklist") }
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

// MARK: - Report window ("Get report now")

enum BannerStyle { case info, warning, error }

final class ReportWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    unowned let app: AppDelegate
    let window: NSWindow
    let periodPopup = NSPopUpButton()
    let datePicker = NSDatePicker()
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
        periodPopup.addItems(withTitles: ["Today so far", "Previous workday", "Pick a date"])
        periodPopup.target = self
        periodPopup.action = #selector(periodChanged)
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.dateValue = Date()
        datePicker.maxDate = Date()
        datePicker.isHidden = true
        datePicker.target = self
        datePicker.action = #selector(periodChanged)
        generateButton.keyEquivalent = "\r"
        generateButton.bezelStyle = .rounded

        let periodLabel = NSTextField(labelWithString: "Report for:")
        let top = NSStackView(views: [periodLabel, periodPopup, datePicker, NSView(), generateButton])
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
        datePicker.isHidden = periodPopup.indexOfSelectedItem != 2
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
        default: return isoDay.string(from: datePicker.dateValue)
        }
    }

    // ---- actions

    @objc func periodChanged() {
        datePicker.isHidden = periodPopup.indexOfSelectedItem != 2
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
        let r = WorklogRun(["report", day, "--json"])
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
            status += " · \(s) session\(s == 1 ? "" : "s"), \(m) logged · \(k) to review"
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
        copyButton.isEnabled = has
        openButton.isEnabled = has
        regenerateButton.isEnabled = !busy && (currentDay != nil)
    }

    // ---- window + web view delegates

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }   // a running report keeps going; we reopen when done

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
        let views: [String: NSView] = ["period": periodPopup, "datePicker": datePicker, "generate": generateButton,
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
        case "period":
            w.periodPopup.selectItem(at: c["index"] as? Int ?? 0)
            if let d = c["date"] as? String, let date = isoDay.date(from: d) { w.datePicker.dateValue = date }
            w.periodChanged()
        case "click":
            let buttons = ["generate": w.generateButton, "cancel": w.cancelButton, "copy": w.copyButton,
                           "open": w.openButton, "regenerate": w.regenerateButton, "close": w.closeButton]
            buttons[c["target"] as? String ?? ""]?.performClick(nil)
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
