import AppKit
import VLCKit
import UniformTypeIdentifiers

@MainActor
final class OriginalPlayer: NSView, NSMenuDelegate {
    private let player = VLCMediaPlayer()
    private let picture = VLCVideoView(frame: .zero)
    private let playButton = NSButton()
    private let subtitles = NSPopUpButton(frame: .zero, pullsDown: true)
    private let audio = NSPopUpButton(frame: .zero, pullsDown: true)
    private let position = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "Opening…")
    private var timer: Timer?
    private var lastSaved = -1
    private let onBack: () -> Void
    private let onProgress: (Double, Double) -> Void
    private let onEpisode: (String) -> Void
    private let nextEpisode: String?
    private let previousEpisode: String?
    private let autoplay: Bool
    private var advanced = false
    private var episodePopover: NSPopover?
    private let controls = NSStackView()
    private var videoAboveControls: NSLayoutConstraint!
    private var videoToBottom: NSLayoutConstraint!
    private var activityMonitor: Any?
    private var acceptedMouseMoves = false
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var cursorHidden = false
    private var menuOpen = false

    init(source: URL, startAt: Double, id: String, episodes: [[String: String]], thumbnailBase: URL, autoplay: Bool,
         onBack: @escaping () -> Void, onProgress: @escaping (Double, Double) -> Void,
         onEpisode: @escaping (String) -> Void) {
        self.onBack = onBack
        self.onProgress = onProgress
        self.onEpisode = onEpisode
        self.autoplay = autoplay
        let index = episodes.firstIndex { $0["id"] == id }
        previousEpisode = index.flatMap { $0 > 0 ? episodes[$0 - 1]["id"] : nil }
        nextEpisode = index.flatMap { $0 + 1 < episodes.count ? episodes[$0 + 1]["id"] : nil }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        picture.setAccessibilityLabel("Original video")
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFullscreen))
        doubleClick.numberOfClicksRequired = 2
        picture.addGestureRecognizer(doubleClick)
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.keyEquivalent = " "
        playButton.keyEquivalentModifierMask = []
        setIcon(playButton, "pause.fill", "Pause")
        position.target = self
        position.action = #selector(seek)
        position.isContinuous = false
        position.isEnabled = false
        position.setAccessibilityLabel("Playback position")
        position.setContentHuggingPriority(.defaultLow, for: .horizontal)
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)

        let volume = NSSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(setVolume(_:)))
        volume.setAccessibilityLabel("Volume")
        volume.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let previous = iconButton("backward.end.fill", "Previous episode", "p", #selector(goPrevious))
        let next = iconButton("forward.end.fill", "Next episode", "n", #selector(goNext))
        previous.isEnabled = previousEpisode != nil
        next.isEnabled = nextEpisode != nil
        let episodePicker = NSButton(title: "Episodes", target: self, action: #selector(showEpisodes(_:)))
        if episodes.count > 1 {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = EpisodePreviewList(episodes: episodes, currentID: id, thumbnailBase: thumbnailBase) { [weak self] id in
                self?.episodePopover?.close()
                self?.onEpisode(id)
            }
            popover.contentSize = NSSize(width: 360, height: min(episodes.count * 69, 410))
            episodePopover = popover
        }
        episodePicker.isHidden = episodes.count < 2
        setupPopup(subtitles, "Subtitles")
        setupPopup(audio, "Audio")
        for picker in [subtitles, audio] { picker.addItem(withTitle: "No tracks available") }
        subtitles.widthAnchor.constraint(equalToConstant: 106).isActive = true
        audio.widthAnchor.constraint(equalToConstant: 83).isActive = true
        subtitles.menu?.delegate = self
        audio.menu?.delegate = self
        let speed = popup("Speed")
        speed.menu?.delegate = self
        for rate in [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] {
            let item = menuItem("\(rate.formatted())×", #selector(selectSpeed(_:)), rate)
            item.state = rate == 1 ? .on : .off
            speed.menu?.addItem(item)
        }
        let transport = row([
            iconButton("chevron.left", "Back", "", #selector(goBack)), previous,
            iconButton("gobackward.10", "Back 10 seconds", "j", #selector(skipBack)), playButton,
            iconButton("goforward.10", "Forward 10 seconds", "l", #selector(skipForward)), next,
            episodePicker, NSView(), subtitles, audio, speed,
            iconButton("arrow.up.left.and.arrow.down.right", "Fullscreen", "f", #selector(toggleFullscreen)),
        ])
        let timeline = row([position, time, iconButton("speaker.slash", "Mute or unmute", "m", #selector(toggleMute)), volume])
        controls.addArrangedSubview(timeline)
        controls.addArrangedSubview(transport)
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        controls.orientation = .vertical
        controls.alignment = .centerX
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        for view in [picture, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        videoAboveControls = picture.bottomAnchor.constraint(equalTo: controls.topAnchor)
        videoToBottom = picture.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            timeline.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -24),
            transport.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -24),
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoAboveControls,
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        player.drawable = picture
        let media = VLCMedia(url: source)
        if startAt > 0 { media.addOption(":start-time=\(startAt)") }
        player.media = media
    }

    func play() {
        if let window {
            acceptedMouseMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
        }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged,
                                                                      .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            if let self, let window = self.window, event.window === window { self.revealControls() }
            return event
        }
        fullscreenChanged()
        player.play()
        timer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(updateControls), userInfo: nil, repeats: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 5
        return stack
    }

    private func setIcon(_ button: NSButton, _ symbol: String, _ label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(label)
        button.toolTip = button.keyEquivalent.isEmpty || button.keyEquivalent == " " ? label : "\(label) (\(button.keyEquivalent.uppercased()))"
    }

    private func iconButton(_ symbol: String, _ label: String, _ key: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = []
        setIcon(button, symbol, label)
        return button
    }

    private func menuItem(_ title: String, _ action: Selector, _ value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    private func setupPopup(_ button: NSPopUpButton, _ title: String) {
        button.addItem(withTitle: title)
        button.setAccessibilityLabel(title)
    }

    private func popup(_ title: String) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        setupPopup(button, title)
        return button
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === subtitles.menu || menu === audio.menu else { return }
        let isSubtitle = menu === subtitles.menu
        let names = isSubtitle ? player.videoSubTitlesNames : player.audioTrackNames
        let indexes = isSubtitle ? player.videoSubTitlesIndexes : player.audioTrackIndexes
        let current = isSubtitle ? player.currentVideoSubTitleIndex : player.currentAudioTrackIndex
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        for (name, index) in zip(names, indexes) {
            guard let track = index as? NSNumber else { continue }
            let title = track.intValue == -1 ? "Off" : (name as? String ?? "Track \(track)")
            let item = menuItem(title, isSubtitle ? #selector(selectSubtitle(_:)) : #selector(selectAudio(_:)), track)
            item.state = track.int32Value == current ? .on : .off
            menu.addItem(item)
        }
        if menu.items.count <= 1 { menu.addItem(NSMenuItem(title: "No tracks available", action: nil, keyEquivalent: "")) }
        if isSubtitle {
            menu.addItem(.separator())
            menu.addItem(menuItem("Add subtitle file…", #selector(addSubtitle)))
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; revealControls() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; revealControls() }

    @objc private func selectSubtitle(_ item: NSMenuItem) {
        if let track = item.representedObject as? NSNumber { player.currentVideoSubTitleIndex = track.int32Value }
    }
    @objc private func selectAudio(_ item: NSMenuItem) {
        if let track = item.representedObject as? NSNumber { player.currentAudioTrackIndex = track.int32Value }
    }
    @objc private func selectSpeed(_ item: NSMenuItem) {
        guard let rate = item.representedObject as? Double else { return }
        player.rate = Float(rate)
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
    }
    @objc private func addSubtitle() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub", "idx"].compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            if self.player.addPlaybackSlave(url, type: .subtitle, enforce: true) != 0 {
                let alert = NSAlert()
                alert.messageText = "Couldn’t load the subtitle file"
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func showEpisodes(_ sender: NSButton) {
        guard let episodePopover else { return }
        if episodePopover.isShown { episodePopover.close() }
        else { episodePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY) }
    }
    @objc private func goPrevious() { if let previousEpisode { onEpisode(previousEpisode) } }
    @objc private func goNext() { if let nextEpisode { onEpisode(nextEpisode) } }
    @objc private func skipBack() { player.jumpBackward(10) }
    @objc private func skipForward() { player.jumpForward(10) }
    @objc private func toggleMute() { if let audio = player.audio { audio.isMuted.toggle() } }

    @objc private func togglePlayback() {
        if player.isPlaying { player.pause() } else { player.play() }
        updateControls()
    }

    @objc private func seek() { if player.isSeekable { player.position = position.floatValue } }
    @objc private func setVolume(_ slider: NSSlider) { player.audio?.volume = Int32(slider.intValue) }
    @objc private func toggleFullscreen() { window?.toggleFullScreen(nil) }
    @objc private func goBack() { onBack() }

    func fullscreenChanged() {
        let fullscreen = window?.styleMask.contains(.fullScreen) == true
        if fullscreen {
            videoAboveControls.isActive = false
            videoToBottom.isActive = true
        } else {
            videoToBottom.isActive = false
            videoAboveControls.isActive = true
        }
        revealControls()
    }

    private func revealControls() {
        lastActivity = ProcessInfo.processInfo.systemUptime
        controls.isHidden = false
        setCursorHidden(false)
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard cursorHidden != hidden else { return }
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
        cursorHidden = hidden
    }

    private func updateFullscreenControls() {
        guard let window, window.styleMask.contains(.fullScreen), player.isPlaying,
              !menuOpen, episodePopover?.isShown != true, window.attachedSheet == nil else {
            revealControls()
            return
        }
        let active = window.isKeyWindow && NSApp.isActive
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if active && (NSEvent.pressedMouseButtons != 0 || (!controls.isHidden && controls.frame.contains(mouse))) {
            revealControls()
            return
        }
        controls.isHidden = ProcessInfo.processInfo.systemUptime - lastActivity >= 3
        setCursorHidden(controls.isHidden && active && picture.frame.contains(mouse))
    }

    @objc private func updateControls() {
        updateFullscreenControls()
        let label = player.isPlaying ? "Pause" : "Play"
        if playButton.accessibilityLabel() != label { setIcon(playButton, player.isPlaying ? "pause.fill" : "play.fill", label) }
        position.isEnabled = player.isSeekable
        if player.position.isFinite { position.floatValue = max(0, player.position) }
        if player.state == .error {
            time.stringValue = "Can’t play this file"
        } else if player.isPlaying || (player.state != .opening && player.state != .buffering) {
            time.stringValue = "\(player.time.stringValue) / \(player.media?.length.stringValue ?? "–")"
        }
        let second = Int(player.time.intValue) / 1000
        if second >= 5 && second / 5 != lastSaved / 5 { saveProgress() }
        if player.state == .ended, autoplay, !advanced, let nextEpisode {
            advanced = true
            onEpisode(nextEpisode)
        }
    }

    private func saveProgress() {
        let seconds = Double(player.time.intValue) / 1000
        let duration = Double(player.media?.length.intValue ?? 0) / 1000
        guard seconds > 0, duration > 0 else { return }
        lastSaved = Int(seconds)
        onProgress(min(seconds, duration), duration)
    }

    func stop() {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        activityMonitor = nil
        window?.acceptsMouseMovedEvents = acceptedMouseMoves
        revealControls()
        episodePopover?.close()
        saveProgress()
        timer?.invalidate()
        timer = nil
        player.stop()
        player.media = nil
        player.drawable = nil
    }
}

@MainActor
private final class EpisodePreviewList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let episodes: [[String: String]]
    private let currentID: String
    private let thumbnailBase: URL
    private let onSelect: (String) -> Void
    private let table = EpisodeTableView()

    init(episodes: [[String: String]], currentID: String, thumbnailBase: URL, onSelect: @escaping (String) -> Void) {
        self.episodes = episodes
        self.currentID = currentID
        self.thumbnailBase = thumbnailBase
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Episode"))
        column.width = 350
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 67
        table.setAccessibilityLabel("Episode previews")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectEpisode(_:))
        scroll.documentView = table
        view = scroll
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let row = episodes.firstIndex(where: { $0["id"] == currentID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        view.window?.makeFirstResponder(table)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { episodes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let episode = episodes[row]
        let id = episode["id"] ?? ""
        let current = id == currentID
        let title = NSTextField(labelWithString: episode["title"] ?? "Episode")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let details = NSTextField(labelWithString: current ? "Now playing" : (episode["duration"] ?? ""))
        details.textColor = .secondaryLabelColor
        details.font = .systemFont(ofSize: 11)
        let labels = NSStackView(views: [title, details])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let preview = NSImageView(image: NSImage(systemSymbolName: "film", accessibilityDescription: nil) ?? NSImage())
        preview.imageScaling = .scaleNone
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        preview.layer?.cornerRadius = 5
        preview.widthAnchor.constraint(equalToConstant: 96).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let rowView = NSStackView(views: [preview, labels])
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 10
        rowView.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        if id.range(of: "^[a-zA-Z0-9_]{1,64}$", options: .regularExpression) != nil {
            let url = thumbnailBase.appendingPathComponent("\(id).jpg")
            Task { [weak preview] in
                guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
                      (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
                preview?.imageScaling = .scaleProportionallyUpOrDown
                preview?.image = image
            }
        }
        return rowView
    }

    @objc private func selectEpisode(_ table: NSTableView) {
        let row = table.selectedRow
        if episodes.indices.contains(row), let id = episodes[row]["id"] { onSelect(id) }
    }
}

private final class EpisodeTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, sendAction(action, to: target) { return }
        super.keyDown(with: event)
    }
}
