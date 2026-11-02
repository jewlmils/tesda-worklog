// TESDA Worklog — tiny menu bar icon.
// Compiled by install.sh with: swiftc -O menubar.swift -o TESDAWorklog
// It just calls worklog.py, which lives in the same folder.

import AppKit

let appDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let script = appDir.appendingPathComponent("worklog.py").path
let python = ProcessInfo.processInfo.environment["WORKLOG_PYTHON"] ?? "/usr/bin/python3"

@discardableResult
func worklog(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: python)
    p.arguments = [script] + args
    p.currentDirectoryURL = appDir
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "Couldn't run worklog.py: \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TESDA Worklog") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "TW"
        }

        let menu = NSMenu()
        add(menu, "Log something…", #selector(logEntry), "l")
        menu.addItem(.separator())
        add(menu, "Report: previous workday", #selector(reportPrevious))
        add(menu, "Report: today so far", #selector(reportToday))
        add(menu, "Open reports folder", #selector(openReports))
        menu.addItem(.separator())
        add(menu, "Settings (config.json)", #selector(openConfig), ",")
        add(menu, "Quit", #selector(quit), "q")
        statusItem.menu = menu
    }

    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc func logEntry() {
        let projects = worklog(["projects"])
            .split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("Created ") }

        let alert = NSAlert()
        alert.messageText = "Log TESDA work"
        alert.informativeText = "Meetings, QA, coordination, docs — anything not done in Claude."

        let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        field.placeholderString = "e.g. Attended TRACK sprint planning"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        popup.addItems(withTitles: projects.isEmpty ? ["General"] : projects)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
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
        if let p = popup.titleOfSelectedItem { args.append("--project=\(p)") }
        worklog(args)
    }

    func runReport(_ args: [String]) {
        statusItem.button?.appearsDisabled = true   // dimmed while Claude writes
        DispatchQueue.global().async {
            worklog(["report"] + args)              // worklog.py notifies + opens the file
            DispatchQueue.main.async { self.statusItem.button?.appearsDisabled = false }
        }
    }

    @objc func reportPrevious() { runReport([]) }
    @objc func reportToday() { runReport(["today"]) }

    @objc func openReports() {
        let dir = appDir.appendingPathComponent("reports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func openConfig() {
        worklog(["projects"])  // creates config.json if it doesn't exist yet
        NSWorkspace.shared.open(appDir.appendingPathComponent("config.json"))
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
