import AppKit

@MainActor
final class DepthPreparationSheet: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 185), styleMask: [.titled], backing: .buffered, defer: false)
    private let message = NSTextField(wrappingLabelWithString: "Starting high-quality 3D preparation…")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let process = Process()
    private var buffer = Data()
    private var cancelled = false
    private var reader: FileHandle?
    private var errors: FileHandle?
    private let cache: PreparedDepthCache
    private let completion: (Result<URL, Error>?) -> Void

    init(cache: PreparedDepthCache, completion: @escaping (Result<URL, Error>?) -> Void) {
        self.cache = cache
        self.completion = completion
        super.init()
        panel.title = "Prepare high-quality 3D"
        progress.isIndeterminate = true; progress.minValue = 0; progress.maxValue = 1
        progress.startAnimation(nil)
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        let note = NSTextField(wrappingLabelWithString: "Creates separate cached depth and Full-SBS files. Your original stays unchanged. Long videos can take considerable time and several GB of disk space.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [message, progress, note, cancelButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func start(window: NSWindow) {
        do {
            guard let resources = Bundle.main.resourceURL else { throw StereoError("The app resources are missing") }
            try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            let errorURL = cache.directory.appendingPathComponent("worker-error.log")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            errors = try FileHandle(forWritingTo: errorURL)
            let pipe = Pipe()
            reader = pipe.fileHandleForReading
            process.executableURL = resources.deletingLastPathComponent().appendingPathComponent("MacOS/ShoeboxDepth")
            process.arguments = [cache.identity.path, String(cache.strength.rawValue), resources.path, cache.directory.deletingLastPathComponent().path]
            process.standardOutput = pipe; process.standardError = errors; process.standardInput = FileHandle.nullDevice
            reader?.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                DispatchQueue.main.async { self?.receive(data) }
            }
            process.terminationHandler = { [weak self] task in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reader?.readabilityHandler = nil
                    try? self.reader?.close()
                    try? self.errors?.close()
                    self.panel.sheetParent?.endSheet(self.panel)
                    self.panel.orderOut(nil)
                    if self.cancelled { self.completion(nil) }
                    else if task.terminationStatus == 0, self.cache.ready { self.completion(.success(self.cache.playbackURL)) }
                    else {
                        let details = ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let reason = details.isEmpty ? "Preparation stopped (exit status \(task.terminationStatus))." : String(details.suffix(1200))
                        self.completion(.failure(StereoError("\(reason)\nCache details: \(self.cache.directory.path)")))
                    }
                }
            }
            window.beginSheet(panel)
            try process.run()
        } catch {
            reader?.readabilityHandler = nil
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
            completion(.failure(error))
        }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty, !cancelled else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let fraction = value["progress"] as? Double, fraction.isFinite else { continue }
            progress.doubleValue = min(1, max(0, fraction))
            progress.isIndeterminate = fraction <= 0
            if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
            message.stringValue = value["message"] as? String ?? "Preparing…"
        }
        if buffer.count > 65536 { buffer.removeAll() }
    }
    @objc func cancel() {
        cancelled = true
        cancelButton.isEnabled = false
        message.stringValue = "Cancelling…"
        if process.isRunning { process.terminate() }
    }
    func cancelAndClose() {
        cancel()
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
    }
}
