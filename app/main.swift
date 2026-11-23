// iCloud Photo Backup - native macOS shell.
// Starts the bundled backup engine (Resources/engine/icpb-engine) on a private
// localhost port and shows its interface in a native window (WebKit).
// Quitting the app pauses the download and stops the engine.

import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var engine: Process?
    var engineURL: URL?
    var allowClose = false
    var logHandle: FileHandle?
    var engineOutput = ""   // recent engine output, shown if it stops unexpectedly

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        startEngine()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: window

    func buildWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "native")
        // Tell the page it runs inside the app, so it can use native dialogs.
        config.userContentController.addUserScript(WKUserScript(
            source: "window.ICPB_NATIVE = true; document.documentElement.classList.add('native');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(loadingHTML("Starting…"), baseURL: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "iCloud Photo Backup"
        window.minSize = NSSize(width: 640, height: 560)
        window.contentView = webView
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func loadingHTML(_ text: String) -> String {
        """
        <html><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
        font:15px -apple-system;color:#888;background:transparent">\(text)</body></html>
        """
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About iCloud Photo Backup",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let site = NSMenuItem(title: "Visit c-na.dev", action: #selector(openDeveloperSite(_:)), keyEquivalent: "")
        site.target = self
        appMenu.addItem(site)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide iCloud Photo Backup", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit iCloud Photo Backup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    // MARK: engine

    func startEngine() {
        let engineDir = Bundle.main.resourceURL!.appendingPathComponent("engine")
        let exe = engineDir.appendingPathComponent("icpb-engine")
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--native", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        var env = ProcessInfo.processInfo.environment
        env["ICPB_PORT"] = "0"   // let the engine pick a free port
        p.environment = env

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iCloudPhotoBackup")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let logURL = support.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self = self else { return }
            self.logHandle?.write(data)
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.engineOutput = String((self.engineOutput + text).suffix(3000))
            }
            guard self.engineURL == nil else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("READY ") {
                if let url = URL(string: String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)) {
                    self.engineURL = url
                    DispatchQueue.main.async { self.webView.load(URLRequest(url: url)) }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            // Give the output reader a moment to deliver the last lines.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self = self, !self.allowClose else { return }
                self.webView.loadHTMLString(self.engineErrorHTML(code: proc.terminationStatus), baseURL: nil)
            }
        }
        do {
            try p.run()
            engine = p
        } catch {
            webView.loadHTMLString(loadingHTML("Could not start the backup engine: \(error.localizedDescription)"), baseURL: nil)
        }
    }

    var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iCloudPhotoBackup/app.log")
    }

    /// Explains why the engine stopped, with the last lines of its output.
    func engineErrorHTML(code: Int32) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let hint: String
        if code == 255 || engineOutput.contains("Failed to load Python") || engineOutput.contains("Library not loaded") {
            hint = """
            The app's built-in Python couldn't start on this Mac. This usually means the copy you have \
            was built for a newer macOS than this Mac runs (\(os)). Download the latest version from \
            <b>github.com/sina-developer/icloud-photo-backup/releases</b>. If that copy also fails, macOS may be \
            blocking it: in Terminal run <code>xattr -dr com.apple.quarantine "/Applications/iCloud Photo Backup.app"</code>, then reopen the app.
            """
        } else {
            hint = "Please reopen the app. If it keeps happening, report it on GitHub with the details below."
        }
        let tail = engineOutput
            .split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <html><head><style>
          body { margin: 0; padding: 48px; font: 14px/1.5 -apple-system; color: #1d1d1f; background: #fff; }
          @media (prefers-color-scheme: dark) { body { color: #f2f2f5; background: #1c1c1f; } pre { background: #111 !important; } }
          h2 { margin: 0 0 10px; font-size: 20px; }
          p { max-width: 640px; color: #6e6e73; }
          code { font: 12px ui-monospace, Menlo, monospace; }
          pre { font: 12px/1.5 ui-monospace, Menlo, monospace; background: #f5f5f7; padding: 12px 14px;
                border-radius: 8px; white-space: pre-wrap; word-break: break-all; max-height: 220px; overflow: auto; }
          button { font: inherit; padding: 7px 14px; border-radius: 8px; border: 1px solid #ccc; background: transparent;
                   color: inherit; cursor: pointer; margin-right: 8px; }
        </style></head><body>
          <h2>The backup engine stopped (code \(code))</h2>
          <p>\(hint)</p>
          <p style="font-size:12px">App \(version) · \(os)</p>
          \(tail.isEmpty ? "" : "<pre>\(tail)</pre>")
          <button onclick="webkit.messageHandlers.native.postMessage({action:'openLog'})">Open Full Log</button>
          <button onclick="webkit.messageHandlers.native.postMessage({action:'openReleases'})">Get Latest Version</button>
        </body></html>
        """
    }

    func stopEngine() {
        guard let p = engine, p.isRunning else { return }
        p.terminate()  // SIGTERM: engine pauses icloudpd cleanly, then exits
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    // MARK: quitting

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowClose { return .terminateNow }
        webView.evaluateJavaScript("(typeof last !== 'undefined' && last) ? last.state : ''") { result, _ in
            let state = result as? String ?? ""
            let busy = ["running", "starting", "needs_input", "retrying"].contains(state)
            if busy {
                let a = NSAlert()
                a.messageText = "Stop the backup and quit?"
                a.informativeText = "Everything downloaded so far stays on your drive. Open the app again and press Resume to continue."
                a.addButton(withTitle: "Quit")
                a.addButton(withTitle: "Keep Running")
                if a.runModal() != .alertFirstButtonReturn {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            self.allowClose = true
            self.stopEngine()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: bridge from the page

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "chooseFolder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use This Folder"
            panel.message = "Choose a folder on your SSD for the photos"
            if let start = body["current"] as? String, !start.isEmpty {
                panel.directoryURL = URL(fileURLWithPath: start)
            } else {
                panel.directoryURL = URL(fileURLWithPath: "/Volumes")
            }
            panel.beginSheetModal(for: window) { resp in
                guard resp == .OK, let url = panel.url else { return }
                let json = String(data: try! JSONSerialization.data(withJSONObject: [url.path]), encoding: .utf8)!
                self.webView.evaluateJavaScript("window.nativeFolderChosen(\(json)[0])")
            }
        case "quit":
            NSApp.terminate(nil)
        case "openLog":
            NSWorkspace.shared.open(logURL)
        case "openReleases":
            NSWorkspace.shared.open(URL(string: "https://github.com/sina-developer/icloud-photo-backup/releases/latest")!)
        default:
            break
        }
    }

    // Links with target="_blank" open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    @objc func openDeveloperSite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://c-na.dev")!)
    }

    // MARK: JS alert/confirm as native sheets

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in completionHandler(r == .alertFirstButtonReturn) }
    }

    // Keep navigation inside the app's own page; open anything else in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let host = url.host, host != "127.0.0.1",
           action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
