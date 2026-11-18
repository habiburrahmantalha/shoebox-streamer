# Changelog

All notable changes to this project are documented here. Shoebox follows [Semantic Versioning](https://semver.org/):
patch releases for fixes, minor releases for new features, and a major release for breaking changes
(CLI flags, config format, or URLs that other devices may have saved).

## [0.7.0] - 2026-11-17

### Added
- Adjust text subtitle size in the native Mac player and remember the selected size.

## [0.6.4] - 2026-11-17

### Fixed
- Make Back visible at the top left of the Mac player when controls are shown, and support Escape to leave fullscreen or return to browsing.

## [0.6.3] - 2026-11-13

### Fixed
- Hide the native toolbar and mouse pointer during idle fullscreen playback, and restore them when playback pauses or you interact with the player.

## [0.6.2] - 2026-11-09

### Added
- Native subtitle and audio selection, playback speed, mute, ten-second skips, and episode controls.
- Double-click the native video to enter or exit fullscreen.
- Browse episodes with thumbnail previews in the native player.

## [0.6.1] - 2026-11-09

### Changed
- Use VLCKit for all Mac app playback in the same window, with direct disk access for local files and original streams for unfinished torrents.
- Save and resume watch progress in the native Mac player.

## [0.6.0] - 2026-11-09

### Added
- Embed VLCKit in the Mac app for original file playback in a native Shoebox window, without a separate VLC install.

## [0.5.3] - 2026-11-09

### Added
- Open original local files from the Mac app in VLC or the default player without streaming or re-encoding.

## [0.5.2] - 2026-11-05

### Fixed
- Use native window fullscreen in the Mac app to avoid moving WebKit's video layer after pause/resume.
- Keep the fullscreen button, Escape, and player close synchronized with the Mac window.

## [0.5.1] - 2026-10-23

### Fixed
- Preserve supported AAC/MP3 audio during HLS streaming instead of always re-encoding to stereo.
- Preserve supported AC-3/E-AC-3 audio through native HLS, with conversion on playback failure.
- Increase required AAC conversion to 320 kbps and retain mono sources as mono.

## [0.5.0] - 2026-10-11

### Added
- Native iPad client with a saved Mac server address and the existing streaming player.
- Mac launcher script to share a selected video folder with an iPad and prevent idle sleep.
- iPad Xcode project, simulator build script, and server address validation checks.
- Automatic Bonjour discovery on iPad with tap to connect, refresh, and manual address fallback.
- iPad loading indicators for connecting, reloading, and waiting for the library to initialize.

### Fixed
- Player Back returns directly to its underlying page instead of relying on WebView history.
- Closing the player ignores late playback responses and cancels pending tap callbacks.

## [0.4.0] - 2026-10-07

### Added
- Standalone macOS app with a native folder picker, remembered library, embedded web player,
  bundled Node.js/FFmpeg/FFprobe, native dialogs and downloads, and managed server lifetime.
- `npm run build:macos` builds a macOS application for the build machine's architecture.

### Fixed
- Loopback-only servers no longer advertise unreachable LAN addresses or mDNS names.
- Watch history is kept separately for each library folder, preserving existing history on upgrade.
- Background FFmpeg/FFprobe jobs are stopped when the server exits.
- Picture-in-picture controls are shown only when the loaded video supports the feature.

## [0.3.0] - 2026-10-07

### Changed
- Torrents now last for one session. They no longer resume automatically when Shoebox starts again. Add the same
  magnet link or `.torrent` file again to continue from what's already downloaded.
- Unfinished downloads stay hidden from the library until their torrent is added again and completes, so
  half-downloaded videos don't show up as broken items.

### Fixed
- A torrent that was already complete when added (for example, added again after it finished) now shows up in the
  library. Previously its files could stay hidden.

## [0.2.2] - 2026-10-05

### Fixed
- Adding a torrent that's already in the list no longer shows an error. Shoebox says "Torrent already added,
  skipping" and carries on. This works whether the duplicate is the same magnet link, a different form of it
  (uppercase or base32 hash, bare info hash), or the matching `.torrent` file, and it covers the command line,
  the web page and torrents resumed at startup.
- A duplicate torrent no longer runs the existing torrent's setup a second time.

## [0.2.1] - 2026-10-02

### Changed
- Shorter package description: "Stream your local videos or torrents to any device on your network."

## [0.2.0] - 2026-10-02

### Added
- `shoebox config`: an interactive setup wizard that saves to `~/.shoebox.conf` (`%USERPROFILE%\.shoebox.conf` on
  Windows; override with `SHOEBOX_CONFIG`). `shoebox config show` prints it with secrets masked, and `shoebox config path` prints its location.
  Settings apply on every run, a missing or unreadable file falls back to defaults, and command-line flags still win.
- Online subtitles from OpenSubtitles (exact matches via file hash) and SubDL, using your own free API keys.
  They download automatically when a video has nothing local in your languages, or you can search from the
  player's subtitle menu. Results are saved next to the video as `<name>.<lang>.srt`.
- Subtitle discovery: files in `Subs/`/`Subtitles/` folders (including `Subs/<episode>/2_English.srt` release
  layouts), any subtitle in a folder that holds a single video, and language/forced/SDH tags read from filenames.
- Automatic subtitle selection: your last choice, then your configured languages, then files beside the video,
  then default or forced embedded tracks. Turning subtitles off is remembered.
- A subtitle timing control in the player (±0.5s steps).

### Changed
- New logo, plus PNG icons so "Add to Home Screen" on iPhone shows the logo.
- Durations under a minute show in seconds instead of "0m".

### Fixed
- Movie posters for films whose Wikipedia summary doesn't mention the release year.
- Subtitle files in Windows-1252 or UTF-16 encodings now display correctly.
- Editing or replacing a subtitle file takes effect without clearing the cache.

## [0.1.0] - 2026-10-02

### Added
- First version: LAN video server with mDNS (`shoebox.local`), show detection, artwork, direct/remux/transcode
  HLS playback, mobile-friendly player, torrent streaming and VLC playlists.
