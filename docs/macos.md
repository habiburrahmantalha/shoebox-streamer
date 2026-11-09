# macOS app

Shoebox's macOS app uses AppKit and WKWebView for its library and VLCKit for playback.
The application bundles Node.js, FFmpeg, FFprobe, VLCKit, and the JavaScript dependencies.
Users do not need a separate VLC installation, Node, Bun, Homebrew, or a copy of the repository.

## Build and run

On a Mac with Node.js 22+, Xcode Command Line Tools, and the project's dependencies installed:

```sh
npm ci --ignore-scripts
npm run build:macos
open dist/Shoebox.app
```

The first build downloads pinned media binaries, the VideoLAN VLCKit framework, and the native prebuild needed by WebTorrent.
Downloads are cached in `.macos-cache/`. The build refuses nonportable binaries that depend on
Homebrew or other libraries outside macOS, verifies signatures, and runs a bundle smoke check.
Output: `dist/Shoebox.app` and `dist/Shoebox-<version>-macos-<architecture>.zip`.
Build on Apple Silicon for arm64 or an Intel Mac for x64. The app targets macOS 13+;
each architecture needs its own build and validation.

Choose a folder in the welcome window, or use **File → Open Video Folder…** (⌘O).
The app remembers the last selected folder. It serves one folder at a time, including subfolders.
Changing the folder restarts the server; incomplete torrents remain on disk and can be re-added.
The app quits its server when the last window closes or you press ⌘Q.

The desktop server binds only `127.0.0.1:7172`, rejects cross-origin requests, and does not announce
a LAN address. Port 7172 is fixed so WebKit's watch history persists across launches. If another
process occupies it, the app shows an error instead of silently changing the storage origin.
The CLI keeps its normal port and network behavior and can run alongside the app.

Settings and history use WebKit's persistent website storage, with watch history separated by
library folder. Folder selection and window geometry use macOS preferences. Server logs are at
`~/Library/Application Support/Shoebox/server.log` and can be opened from the File menu.
The existing `~/.shoebox.conf` settings still apply, except desktop binding/port/mDNS overrides.
Media metadata and thumbnails use the existing `.shoebox` cache in the selected folder.

## Playback

Choose **Play** or click a video to open the native player in the same window. Local files play
directly from disk; unfinished torrents use their original stream. Neither path re-encodes the media.
The controls support pause, seeking, ten-second skips, volume, speed, and audio and subtitle
track selection. Use **Subtitles → Add subtitle file…** to load a separate subtitle. Use
**Episodes** to browse thumbnail previews or the previous and next buttons to switch episodes. Double-click the video or
press **F** to toggle fullscreen. **Back** returns to the library and saves your playback position.

## Browser streaming quality

The browser player plays the original file directly when it supports the container,
video, and selected audio track. Keep Quality on Auto to avoid requesting video conversion.
MKV and unsupported codecs may still require HLS streaming. Compatible AAC and MP3 audio
is copied without re-encoding, even when the video needs conversion. Supported AC-3/E-AC-3
tracks use native HLS to retain their original audio and channel count. If playback fails,
Shoebox retries with AAC conversion. Other unsupported audio is converted to 320 kbps AAC,
with at most two channels for compatibility; this fallback cannot retain lossless or surround audio.

## Validation

```sh
npm test
node scripts/check-macos.mjs dist/Shoebox.app
```

The bundle check creates a temporary library containing a generated video, removes Homebrew
and Node from PATH, and checks bundled media tools, a Unicode folder path, static UI assets,
library discovery, native torrent support, byte ranges, direct playback, HLS transcoding, loopback-only
addresses, cross-origin rejection, and server shutdown. It does not download a public torrent.
Selection/cancellation, folder switching, video playback, fullscreen, and quit/relaunch were
checked interactively on Apple Silicon. PiP is shown only when the media engine reports support;
its native floating-window behavior still needs validation. Downloads, external players,
sleep/wake, and a clean second Mac also need a release validation pass.

## Distribution

The default build is ad-hoc signed for local testing. For a Developer ID build:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" npm run build:macos
```

The build signs native helpers and enables the hardened runtime; Node receives its JIT entitlement.
Notarize the archive with your Apple Developer credentials, staple the ticket to the app, verify
Gatekeeper acceptance, and recreate the archive before public distribution. Credentials and
certificates are not stored in this repository. Bundled dependency licenses and media-build
provenance are included; review FFmpeg redistribution requirements before publishing.

## Next improvements

- Multiple libraries with stable IDs and history migration if a folder moves.
- Native settings for subtitle providers, downloads, cache limits, and explicit LAN sharing.
- External-drive reconnect recovery, library health reporting, and metadata correction.
- Media keys/Now Playing, sleep prevention, and optional background/menu-bar operation.
- Signed updates, Intel validation, clean-machine testing, and notarized releases.

This build is distributed directly, outside the Mac App Store, and does not adopt App Sandbox.
An App Store version needs a separate sandbox/permissions design, including persistent folder
bookmarks and access for the bundled server and media helpers.
