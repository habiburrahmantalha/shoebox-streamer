import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate,
                         WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let welcome = NSStackView()
    private let status = NSTextField(labelWithString: "Choose a folder of videos to start watching.")
    private let spinner = NSProgressIndicator()
    private var server: Process?
    private var readyTimer: Timer?
    private var sessionDir: URL?
    private var serverURL: URL?
    private var folder: URL?
    private var logHandle: FileHandle?
    private var afterStop: (() -> Void)?
    private let defaults = UserDefaults.standard
    private let port = 7172 // Stable origin keeps WebKit watch history across launches.
    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shoebox", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(self, name: "shoeboxFullscreen")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isHidden = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Shoebox"
        window.minSize = NSSize(width: 680, height: 480)
        window.delegate = self
        window.setFrameAutosaveName("ShoeboxWindow")
        let content = window.contentView!
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let title = NSTextField(labelWithString: "Your videos. Your Mac.")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        status.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        let choose = NSButton(title: "Choose Video Folder…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        choose.keyEquivalent = "\r"
        welcome.orientation = .vertical
        welcome.spacing = 16
        for view in [icon, title, status, spinner, choose] { welcome.addArrangedSubview(view) }
        welcome.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(welcome)
        NSLayoutConstraint.activate([
            welcome.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        if !window.setFrameUsingName("ShoeboxWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let initial = defaults.string(forKey: "libraryFolder")
        if let initial { selectFolder(URL(fileURLWithPath: initial)) }
    }

    private func makeMenus() {
        let menu = NSMenu()
        func section(_ title: String, _ items: [(String, Selector?, String)]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            for (label, action, key) in items {
                if label.isEmpty { submenu.addItem(.separator()); continue }
                let entry = NSMenuItem(title: label, action: action, keyEquivalent: key)
                if title != "Edit" && title != "Window" { entry.target = self }
                submenu.addItem(entry)
            }
            item.submenu = submenu
            menu.addItem(item)
            if title == "Window" { NSApp.windowsMenu = submenu }
        }
        section("Shoebox", [("About Shoebox", #selector(about), ""), ("", nil, ""),
                            ("Quit Shoebox", #selector(quit), "q")])
        section("File", [("Open Video Folder…", #selector(chooseFolder), "o"),
                         ("Reveal Folder in Finder", #selector(revealFolder), ""),
                         ("Open Server Log", #selector(openLog), "")])
        section("Edit", [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                         ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                         ("Select All", #selector(NSText.selectAll(_:)), "a")])
        section("View", [("Reload", #selector(reload), "r")])
        section("Window", [("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                           ("Zoom", #selector(NSWindow.performZoom(_:)), "")])
        NSApp.mainMenu = menu
    }

    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func reload() { webView.reload() }
    @objc private func revealFolder() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }
    @objc private func openLog() { NSWorkspace.shared.open(support.appendingPathComponent("server.log")) }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your video folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.selectFolder(url) }
        }
    }

    private func selectFolder(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
            showError("Folder unavailable", "Reconnect the drive or choose another readable video folder.")
            return
        }
        webView.isHidden = true
        webView.loadHTMLString("", baseURL: nil)
        welcome.isHidden = false
        status.stringValue = "Starting your library…"
        spinner.startAnimation(nil)
        stopServer { [weak self] in self?.startServer(url) }
    }

    private func startServer(_ url: URL) {
        let process = Process()
        do {
            let resources = Bundle.main.resourceURL!
            let runtime = resources.appendingPathComponent("runtime")
            let app = resources.appendingPathComponent("server")
            let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            sessionDir = session
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let logURL = support.appendingPathComponent("server.log")
            try Data().write(to: logURL)
            logHandle = try FileHandle(forWritingTo: logURL)
            process.executableURL = runtime.appendingPathComponent("node")
            process.arguments = [app.appendingPathComponent("bin/shoebox.js").path, url.path,
                                 "--host", "127.0.0.1", "--no-mdns", "--port", String(port)]
            process.currentDirectoryURL = app
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin"
            environment.removeValue(forKey: "NODE_OPTIONS")
            environment.removeValue(forKey: "NODE_PATH")
            environment["SHOEBOX_FFMPEG"] = runtime.appendingPathComponent("ffmpeg").path
            environment["SHOEBOX_FFPROBE"] = runtime.appendingPathComponent("ffprobe").path
            environment["SHOEBOX_DESKTOP_READY"] = session.appendingPathComponent("ready.json").path
            environment["NO_COLOR"] = "1"
            process.environment = environment
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { self?.serverStopped(process) }
            }
            server = process
            try process.run()
            folder = url
            window.title = "Shoebox — \(url.lastPathComponent)"
            let deadline = Date().addingTimeInterval(30)
            readyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkReady(deadline: deadline) }
            }
        } catch {
            server = nil
            cleanSession()
            showError("Couldn’t start Shoebox", error.localizedDescription)
        }
    }

    private func checkReady(deadline: Date) {
        guard let sessionDir, let folder else { return }
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("ready.json")),
           let ready = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           ready["port"] as? Int == port, ready["root"] as? String == folder.path {
            readyTimer?.invalidate()
            readyTimer = nil
            defaults.set(folder.path, forKey: "libraryFolder")
            serverURL = URL(string: "http://127.0.0.1:\(port)")!
            webView.load(URLRequest(url: serverURL!))
        } else if Date() > deadline {
            stopServer { [weak self] in
                self?.showError("Startup timed out", "Open File → Open Server Log for details, then choose the folder again.")
            }
        }
    }

    private func stopServer(_ completion: @escaping () -> Void) {
        readyTimer?.invalidate()
        readyTimer = nil
        webView.stopLoading()
        serverURL = nil
        guard let server, server.isRunning else { cleanSession(); completion(); return }
        afterStop = completion
        server.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak server] in
            if let server, self?.server === server, server.isRunning { kill(server.processIdentifier, SIGKILL) }
        }
    }

    private func serverStopped(_ process: Process) {
        guard server === process else { return }
        server = nil
        cleanSession()
        if let completion = afterStop { afterStop = nil; completion(); return }
        let log = (try? String(contentsOf: support.appendingPathComponent("server.log"), encoding: .utf8)) ?? ""
        showError("Shoebox stopped", String(log.suffix(1600)) + "\nChoose a folder to restart. If port 7172 is occupied, quit the other Shoebox app first.")
    }

    private func cleanSession() {
        readyTimer?.invalidate()
        readyTimer = nil
        try? logHandle?.close()
        logHandle = nil
        if let sessionDir { try? FileManager.default.removeItem(at: sessionDir) }
        sessionDir = nil
    }

    private func showError(_ title: String, _ message: String) {
        spinner.stopAnimation(nil)
        webView.isHidden = true
        welcome.isHidden = false
        status.stringValue = "Choose a folder to start your library."
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard server?.isRunning == true else { cleanSession(); return .terminateNow }
        stopServer { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func isLocal(_ url: URL?) -> Bool {
        guard let url, let serverURL else { return false }
        return url.scheme == serverURL.scheme && url.host == serverURL.host && url.port == serverURL.port
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "shoeboxFullscreen", message.frameInfo.isMainFrame,
              isLocal(message.frameInfo.request.url), let command = message.body as? String else { return }
        if command == "toggle" || (command == "exit" && window.styleMask.contains(.fullScreen)) {
            // Keep WebKit's video layer in place rather than fullscreening the DOM element.
            window.toggleFullScreen(nil)
        }
    }

    private func syncFullscreen() {
        guard isLocal(webView.url) else { return }
        let fullscreen = window.styleMask.contains(.fullScreen) ? "true" : "false"
        webView.evaluateJavaScript("window.shoeboxFullscreen = \(fullscreen); window.dispatchEvent(new Event('shoeboxfullscreenchange'))", completionHandler: nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { syncFullscreen() }
    func windowDidExitFullScreen(_ notification: Notification) { syncFullscreen() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isLocal(webView.url) else { return }
        spinner.stopAnimation(nil)
        welcome.isHidden = true
        webView.isHidden = false
        window.makeFirstResponder(webView)
        syncFullscreen()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showError("Couldn’t load your library", error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if isLocal(action.request.url) { decisionHandler(action.shouldPerformDownload ? .download : .allow); return }
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https", "vlc"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.hasPrefix("attachment") == true
        decisionHandler(attachment || !response.canShowMIMEType ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.url : nil) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if (error as NSError).code != NSURLErrorCancelled {
            let alert = NSAlert()
            alert.messageText = "Download failed"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard isLocal(frame.request.url) else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard isLocal(frame.request.url) else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard isLocal(frame.request.url) else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}

@main
struct ShoeboxApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
