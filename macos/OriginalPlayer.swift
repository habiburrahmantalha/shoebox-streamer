import AppKit
import VLCKit
import UniformTypeIdentifiers
import Metal

@MainActor
final class OriginalPlayer: NSView, NSMenuDelegate {
    private static let subtitleSizes = [50, 75, 100, 125, 150, 175, 200]
    private static let subtitleSizeKey = "subtitleSizePercent"
    private var subtitleSize = 100
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
    private let backButton = NSButton()
    private var videoAboveControls: NSLayoutConstraint!
    private var videoToBottom: NSLayoutConstraint!
    private var activityMonitor: Any?
    private var acceptedMouseMoves = false
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var cursorHidden = false
    private var menuOpen = false
    private var stereoMode: StereoMode
    private let stereoPreferenceKey: String
    private var appliedStereoRatio: String?
    private let source: URL
    private let initialPosition: Double
    private var started = false
    private var stopped = false
    private var restarting = false
    private var pauseAfterRestart = false
    private var restoreTracks: (audio: Int32, subtitle: Int32)?
    private var aiView: AIStereoView?
    private var depthProcessor: StereoDepthProcessor?
    private var videoFrames: ShoeboxVideoFrames?
    private var loadingGeneration = UUID()
    private let aiLoading = NSStackView()
    private let stereoPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private var depthStrength = StereoDepthStrength(rawValue: UserDefaults.standard.float(forKey: "aiDepthStrength")) ?? .balanced
    private var externalSubtitles: [URL] = []
    private var preparation: DepthPreparationSheet?
    private var preparedSource: URL?

    init(source: URL, startAt: Double, id: String, episodes: [[String: String]], thumbnailBase: URL, autoplay: Bool,
         onBack: @escaping () -> Void, onProgress: @escaping (Double, Double) -> Void,
         onEpisode: @escaping (String) -> Void) {
        self.onBack = onBack
        self.onProgress = onProgress
        self.onEpisode = onEpisode
        self.autoplay = autoplay
        self.source = source
        initialPosition = startAt
        stereoPreferenceKey = "stereoMode:\(id)"
        stereoMode = StereoMode(rawValue: UserDefaults.standard.string(forKey: stereoPreferenceKey) ?? "") ?? .normal
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
        let stereo = stereoPicker
        setupPopup(stereo, "3D")
        stereo.menu?.delegate = self
        stereo.toolTip = "For RayNeo: enable the glasses’ SBS 3D mode, then fullscreen Shoebox on the 3840×1080 display."
        for mode in StereoMode.allCases {
            let item = menuItem(mode.title, #selector(selectStereoMode(_:)), mode.rawValue)
            item.state = mode == stereoMode ? .on : .off
            stereo.menu?.addItem(item)
        }
        let strengths = NSMenu(title: "AI Depth")
        strengths.delegate = self
        for strength in StereoDepthStrength.allCases {
            let item = menuItem(strength.title, #selector(selectDepthStrength(_:)), strength.rawValue)
            item.state = strength == depthStrength ? .on : .off
            strengths.addItem(item)
        }
        stereo.menu?.addItem(.separator())
        let depthItem = NSMenuItem(title: "AI Depth", action: nil, keyEquivalent: "")
        depthItem.submenu = strengths
        stereo.menu?.addItem(depthItem)
        backButton.title = "Back"
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = "Return to the library or episode list"
        let transport = row([
            previous,
            iconButton("gobackward.10", "Back 10 seconds", "j", #selector(skipBack)), playButton,
            iconButton("goforward.10", "Forward 10 seconds", "l", #selector(skipForward)), next,
            episodePicker, NSView(), subtitles, audio, speed, stereo,
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
        for view in [picture, controls, backButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        videoAboveControls = picture.bottomAnchor.constraint(equalTo: controls.topAnchor)
        videoToBottom = picture.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
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

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let loadingLabel = NSTextField(labelWithString: "Preparing AI 3D…")
        aiLoading.addArrangedSubview(spinner)
        aiLoading.addArrangedSubview(loadingLabel)
        aiLoading.spacing = 10
        aiLoading.wantsLayer = true
        aiLoading.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        aiLoading.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        aiLoading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(aiLoading)
        NSLayoutConstraint.activate([aiLoading.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
                                     aiLoading.centerYAnchor.constraint(equalTo: picture.centerYAnchor)])
        aiLoading.isHidden = true
    }

    func play() {
        let preferredSize = UserDefaults.standard.integer(forKey: Self.subtitleSizeKey)
        if Self.subtitleSizes.contains(preferredSize), ShoeboxSetSubtitleScale(player, Int32(preferredSize)) {
            subtitleSize = preferredSize
        }
        if let window {
            acceptedMouseMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
        }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged,
                                                                      .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            self.revealControls()
            if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               !self.menuOpen, self.episodePopover?.isShown != true, window.attachedSheet == nil {
                if event.isARepeat { return nil }
                if window.styleMask.contains(.fullScreen) { self.toggleFullscreen() }
                else { self.goBack() }
                return nil
            }
            return event
        }
        fullscreenChanged()
        if stereoMode == .aiFullSBS { prepareAI() }
        else if stereoMode == .preparedSBS { prepareHighQuality() }
        else { player.play(); started = true }
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
            let sizes = NSMenu(title: "Size")
            for percent in Self.subtitleSizes {
                let title = percent == 100 ? "100% (Default)" : "\(percent)%"
                let item = menuItem(title, #selector(selectSubtitleSize(_:)), percent)
                item.state = percent == subtitleSize ? .on : .off
                sizes.addItem(item)
            }
            let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
            size.submenu = sizes
            menu.addItem(size)
            menu.addItem(menuItem("Add subtitle file…", #selector(addSubtitle)))
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; revealControls() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; revealControls() }

    @objc private func selectSubtitle(_ item: NSMenuItem) {
        if let track = item.representedObject as? NSNumber { player.currentVideoSubTitleIndex = track.int32Value }
    }
    @objc private func selectSubtitleSize(_ item: NSMenuItem) {
        guard let percent = item.representedObject as? Int, Self.subtitleSizes.contains(percent),
              ShoeboxSetSubtitleScale(player, Int32(percent)) else { return }
        subtitleSize = percent
        UserDefaults.standard.set(percent, forKey: Self.subtitleSizeKey)
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
    }
    @objc private func selectAudio(_ item: NSMenuItem) {
        if let track = item.representedObject as? NSNumber { player.currentAudioTrackIndex = track.int32Value }
    }
    @objc private func selectSpeed(_ item: NSMenuItem) {
        guard let rate = item.representedObject as? Double else { return }
        player.rate = Float(rate)
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
    }
    @objc private func selectStereoMode(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let mode = StereoMode(rawValue: value) else { return }
        guard mode != stereoMode else { return }
        stereoMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: stereoPreferenceKey)
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        loadingGeneration = UUID()
        aiLoading.isHidden = true
        if mode == .aiFullSBS { prepareAI() }
        else if mode == .preparedSBS { prepareHighQuality() }
        else if preparedSource != nil {
            preparedSource = nil
            restartVideoOutput()
        }
        else if videoFrames != nil { restartVideoOutput() }
        else {
            applyStereoMode()
            if !started { player.play(); started = true }
        }
    }

    @objc private func selectDepthStrength(_ item: NSMenuItem) {
        guard let value = item.representedObject as? Float, let strength = StereoDepthStrength(rawValue: value) else { return }
        depthStrength = strength
        UserDefaults.standard.set(strength.rawValue, forKey: "aiDepthStrength")
        aiView?.depthStrength = strength
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        if stereoMode == .preparedSBS { prepareHighQuality() }
    }

    private func prepareHighQuality() {
        guard preparation == nil, !stopped, let window else { return }
        do {
            let cache = try PreparedDepthCache(source: source, strength: depthStrength)
            if cache.ready {
                preparedSource = cache.playbackURL
                restartVideoOutput()
                return
            }
            let resume = !started || player.isPlaying
            if started { player.pause() }
            depthProcessor?.cancel()
            let sheet = DepthPreparationSheet(cache: cache) { [weak self] result in
                guard let self, !self.stopped else { return }
                self.preparation = nil
                switch result {
                case .success(let url):
                    self.preparedSource = url
                    self.restartVideoOutput(resumePlaying: resume)
                case .failure(let error): self.failAI(error)
                case nil:
                    self.stereoMode = .normal
                    self.preparedSource = nil
                    UserDefaults.standard.set(self.stereoMode.rawValue, forKey: self.stereoPreferenceKey)
                    self.updateStereoSelection()
                    self.restartVideoOutput(resumePlaying: resume)
                }
            }
            preparation = sheet
            sheet.start(window: window)
        } catch { failAI(error) }
    }

    private func updateStereoSelection() {
        stereoPicker.menu?.items.forEach { $0.state = ($0.representedObject as? String) == stereoMode.rawValue ? .on : .off }
    }

    private func prepareAI() {
        let generation = UUID()
        loadingGeneration = generation
        aiLoading.isHidden = false
        stereoPicker.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (StereoDepthProcessor, StereoMetalRenderer) in
                guard let device = MTLCreateSystemDefaultDevice(),
                      let model = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
                    throw StereoError("The bundled AI depth model or Metal is unavailable")
                }
                return (try StereoDepthProcessor(modelURL: model, device: device), try StereoMetalRenderer(device: device))
            }
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.loadingGeneration == generation, self.stereoMode == .aiFullSBS else { return }
                switch result {
                case .success(let (processor, renderer)):
                    self.depthProcessor = processor
                    let view = AIStereoView(renderer: renderer)
                    view.depthStrength = self.depthStrength
                    view.onFailure = { [weak self] error in self?.failAI(error) }
                    let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(self.toggleFullscreen))
                    doubleClick.numberOfClicksRequired = 2
                    view.addGestureRecognizer(doubleClick)
                    view.translatesAutoresizingMaskIntoConstraints = false
                    self.addSubview(view, positioned: .above, relativeTo: self.picture)
                    NSLayoutConstraint.activate([
                        view.topAnchor.constraint(equalTo: self.picture.topAnchor),
                        view.bottomAnchor.constraint(equalTo: self.picture.bottomAnchor),
                        view.leadingAnchor.constraint(equalTo: self.picture.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: self.picture.trailingAnchor),
                    ])
                    self.aiView = view
                    self.restartVideoOutput()
                case .failure(let error): self.failAI(error)
                }
            }
        }
    }

    private func failAI(_ error: Error) {
        guard !stopped, stereoMode == .aiFullSBS || stereoMode == .preparedSBS else { return }
        stereoMode = .normal
        loadingGeneration = UUID()
        aiLoading.isHidden = true
        stereoPicker.isEnabled = true
        UserDefaults.standard.set(stereoMode.rawValue, forKey: stereoPreferenceKey)
        updateStereoSelection()
        let hadPreparedSource = preparedSource != nil
        preparedSource = nil
        if videoFrames != nil || hadPreparedSource { restartVideoOutput() }
        else if !started { player.play(); started = true }
        let alert = NSAlert()
        alert.messageText = "3D couldn’t start"
        alert.informativeText = "\(error.localizedDescription)\nNormal playback is available."
        if let window { alert.beginSheetModal(for: window) }
    }

    private func restartVideoOutput(resumePlaying: Bool? = nil) {
        guard !restarting, !stopped else { return }
        restarting = true
        stereoPicker.isEnabled = false
        let seconds = started ? max(0, Double(player.time.intValue) / 1000) : initialPosition
        let wasPlaying = resumePlaying ?? (!started || player.isPlaying)
        let tracks = (audio: player.currentAudioTrackIndex, subtitle: player.currentVideoSubTitleIndex)
        ShoeboxStopPlayer(player) { [weak self] in
            guard let self, !self.stopped else { return }
            self.finishVideoOutputChange(seconds: seconds, wasPlaying: wasPlaying, tracks: tracks)
        }
    }

    private func finishVideoOutputChange(seconds: Double, wasPlaying: Bool, tracks: (audio: Int32, subtitle: Int32)) {
        videoFrames?.detach(from: player)
        videoFrames = nil
        appliedStereoRatio = nil
        player.videoAspectRatio = nil
        if stereoMode == .aiFullSBS, let processor = depthProcessor, let view = aiView {
            let frames = ShoeboxVideoFrames { [weak self, weak view] frame in
                processor.submit(frame) { result in
                    guard let self, !self.stopped, self.aiView === view, self.stereoMode == .aiFullSBS else { return }
                    switch result {
                    case .success(let depth):
                        self.aiLoading.isHidden = true
                        self.stereoPicker.isEnabled = true
                        view?.show(frame: frame, depth: depth)
                        if self.pauseAfterRestart { self.pauseAfterRestart = false; self.player.pause() }
                    case .failure(let error): self.failAI(error)
                    }
                }
            }
            videoFrames = frames
            player.drawable = nil
            frames.attach(to: player)
            picture.isHidden = true
        } else {
            depthProcessor?.cancel()
            depthProcessor = nil
            aiView?.removeFromSuperview()
            aiView = nil
            picture.isHidden = false
            player.drawable = picture
            stereoPicker.isEnabled = true
        }
        let media = VLCMedia(url: stereoMode == .preparedSBS ? (preparedSource ?? source) : source)
        if seconds > 0 { media.addOption(":start-time=\(seconds)") }
        player.media = media
        restoreTracks = started ? tracks : nil
        pauseAfterRestart = !wasPlaying
        restarting = false
        player.play()
        for url in externalSubtitles { _ = player.addPlaybackSlave(url, type: .subtitle, enforce: false) }
        started = true
    }

    private func applyStereoMode() {
        guard videoFrames == nil else { return }
        let size = player.videoSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width < CGFloat(Int.max / 2), size.height < CGFloat(Int.max) else { return }
        let ratio = stereoMode.aspectRatio(width: Int(size.width), height: Int(size.height))
        guard ratio != appliedStereoRatio else { return }
        // Render both eye images without cropping or encoding a new video.
        picture.fillScreen = false
        player.videoCropGeometry = nil
        player.scaleFactor = 0
        if let ratio {
            ratio.withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        } else {
            player.videoAspectRatio = nil
        }
        appliedStereoRatio = ratio
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
            } else { self.externalSubtitles.append(url) }
        }
    }

    @objc private func showEpisodes(_ sender: NSButton) {
        guard let episodePopover else { return }
        if episodePopover.isShown { episodePopover.close() }
        else { episodePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY) }
    }
    @objc private func goPrevious() { if let previousEpisode { onEpisode(previousEpisode) } }
    @objc private func goNext() { if let nextEpisode { onEpisode(nextEpisode) } }
    @objc private func skipBack() { if !restarting { player.jumpBackward(10) } }
    @objc private func skipForward() { if !restarting { player.jumpForward(10) } }
    @objc private func toggleMute() { if let audio = player.audio { audio.isMuted.toggle() } }

    @objc private func togglePlayback() {
        guard !restarting else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        started = true
        updateControls()
    }

    @objc private func seek() { if !restarting, player.isSeekable { player.position = position.floatValue } }
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
        backButton.isHidden = false
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
        let overControls = !controls.isHidden && (controls.frame.contains(mouse) || backButton.frame.contains(mouse))
        if active && (NSEvent.pressedMouseButtons != 0 || overControls) {
            revealControls()
            return
        }
        controls.isHidden = ProcessInfo.processInfo.systemUptime - lastActivity >= 3
        backButton.isHidden = controls.isHidden
        setCursorHidden(controls.isHidden && active && picture.frame.contains(mouse))
    }

    @objc private func updateControls() {
        if restarting { time.stringValue = "Switching video output…"; return }
        if player.state == .error, stereoMode == .aiFullSBS || stereoMode == .preparedSBS {
            if stereoMode == .preparedSBS, let preparedSource { try? FileManager.default.removeItem(at: preparedSource) }
            failAI(StereoError("VLC couldn’t open this 3D video. Normal playback is available."))
        }
        if player.isPlaying {
            if let tracks = restoreTracks {
                player.currentAudioTrackIndex = tracks.audio
                player.currentVideoSubTitleIndex = tracks.subtitle
                restoreTracks = nil
            }
            if pauseAfterRestart, aiLoading.isHidden {
                pauseAfterRestart = false
                player.pause()
            }
        }
        applyStereoMode()
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
        stopped = true
        loadingGeneration = UUID()
        depthProcessor?.cancel()
        preparation?.cancelAndClose()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        activityMonitor = nil
        window?.acceptsMouseMovedEvents = acceptedMouseMoves
        revealControls()
        episodePopover?.close()
        saveProgress()
        timer?.invalidate()
        timer = nil
        let frames = videoFrames
        videoFrames = nil
        let player = self.player
        let picture = self.picture
        ShoeboxStopPlayer(player) {
            frames?.detach(from: player)
            player.media = nil
            player.drawable = nil
            withExtendedLifetime(picture) {}
        }
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
