# macOS app

Shoebox's macOS app uses AppKit and WKWebView for its library and VLCKit for playback.
The application bundles Node.js, FFmpeg, FFprobe, VLCKit, and the JavaScript dependencies.
Users do not need a separate VLC installation, Node, Bun, Homebrew, or a copy of the repository.

## Build and run

On a Mac with Node.js 22+, Xcode (including the Core ML compiler), Python 3.11 for the first
video-depth conversion build, and the project's dependencies installed:

```sh
npm ci --ignore-scripts
npm run build:macos
open dist/Shoebox.app
```

The first build downloads pinned media binaries, the VideoLAN VLCKit framework, Apple's approximately 50 MB
Depth Anything V2 Small F16 model, the approximately 114 MB Video Depth Anything Small checkpoint,
and the native prebuild needed by WebTorrent. The video-depth model is converted in a private
`.macos-cache/depth-convert-env` environment using pinned build dependencies, and validated against
the original PyTorch model. Set `SHOEBOX_MODEL_PYTHON` if Python 3.11 has a different executable path.
Build dependencies and PyTorch are not included in the installed application.
Both depth modes use Core ML's CPU/GPU path. This avoids a Neural Engine compilation stall
observed on the development Mac; real-time inference may be slower, while prepared playback
does not run the depth model.
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
track selection. Use **Subtitles → Size** to resize text subtitles; Shoebox remembers your
choice. Image-based and burned-in subtitles cannot be resized. Use **Subtitles → Add subtitle file…**
to load a separate subtitle. Use
**Episodes** to browse thumbnail previews or the previous and next buttons to switch episodes.
Double-click the video or press **F** to toggle fullscreen. Move the pointer to reveal the
controls in fullscreen. **Back** at the top left returns to browsing and saves your playback
position. **Escape** exits fullscreen first, or returns to browsing when windowed.

## SBS 3D on RayNeo Air 4 Pro

Use the native player's **3D** menu:

- **2D → Full-SBS (AI, Experimental)** estimates depth on this Mac and generates different left/right
  eye views from ordinary 2D footage. Enable it for 2D sources, rather than videos already encoded in 3D.
- **2D → Full-SBS (Prepare HQ…)** preprocesses a completed local video with the temporal video-depth
  model, then plays a cached Full-SBS file. Preparation shows progress and supports Cancel.
- **Half-SBS → Full-SBS** expands a half-width SBS image during playback. For example,
  a 1920×1080 frame is displayed at a 3840:1080 aspect ratio, retaining both eye views.
- **Full-SBS (Already full width)** preserves the original full-width SBS layout.
- **Off (Normal video)** restores the source's normal aspect ratio.

The selection is remembered per video. All modes leave the source file unchanged and keep audio
in VLC. Real-time AI conversion runs in memory, with no output video file or network model service. The bundled
[Apple Core ML model](https://huggingface.co/apple/coreml-depth-anything-v2-small) runs on device;
no Python installation or runtime download is needed. A loading indicator appears while it initializes.
Choosing **Off** restores normal native VLC output; changing between AI and native output briefly
reopens the source at the current playback time.

Choose **3D → AI Depth → Gentle / Balanced / Strong** to adjust stereo separation. Real-time mode
updates immediately; HQ mode renders a new prepared version using the existing depth cache.
Balanced is the default; the chosen strength is remembered across videos.
Strong gives more pronounced depth but can increase edge distortion. Gentle uses the 0.9.0
eye-separation setting with the new depth processing. Processing expands compressed depth ranges
and smooths stable pixels. Moving pixels reject previous depth; detected scene changes and long
frame gaps reset history to limit depth trails.

The stereo renderer projects source pixels into each eye with nearer surfaces winning overlaps,
uses image color to refine low-resolution depth boundaries, and fills newly exposed gaps from
the background side. This avoids the extra foreground strips produced by a simple inverse warp.
Depth boundaries skip temporal blending to reduce trailing outlines during movement. Hidden
background gaps use reflected nearby background texture rather than a stretched border column,
and strong image edges skip color interpolation to limit blurry rims. Reconstructed background
may repeat nearby patterns and is still an approximation; the app cannot recover detail absent from the
original 2D frame. See the [background-reconstruction research](https://openaccess.thecvf.com/content_cvpr_2016/papers/Luo_A_Hole_Filling_CVPR_2016_paper.pdf)
for the underlying disocclusion problem.

AI mode remains an approximation, with possible edge warping, depth flicker, and errors on
transparent objects or scene cuts. It uses 8-bit SDR frames capped at 1920×1080 per eye, preserving
the source aspect ratio inside each eye. It does not preserve HDR or add missing image detail.
Frames are dropped when inference cannot keep up, so high-frame-rate video and slower Macs can look
less smooth. Ordinary playback and existing SBS modes retain the native video path.
Expanding Half-SBS does not recover detail missing from the source or handle top-and-bottom 3D.

Connect the glasses as a Mac display, enable their hardware SBS 3D mode, and use the
3840×1080 display mode. Move Shoebox onto that display and enter fullscreen. The app does
not switch the glasses' hardware mode or macOS display settings. RayNeo lists 3840×1080
for 3D input in its [Air 4 Pro specifications](https://www.rayneo.com/products/connect-any-device-with-ease-rayneo-air-4-pro-hdmi-adapter).
The glasses are needed to verify eye alignment; the Mac display alone shows two pictures.
Shoebox does not duplicate its toolbar for each eye. In AI mode VLC subtitles are part of the
decoded picture and are included in both generated eye views, but can be distorted by the depth
warp. Existing SBS modes do not duplicate ordinary subtitles. Turn subtitles off if they appear
split or uncomfortable in 3D. Physical glasses alignment and comfort still need a RayNeo test.

### High-quality preprocessing

HQ mode uses [Video Depth Anything Small](https://github.com/DepthAnything/Video-Depth-Anything),
a video-trained temporal model rather than independent frame inference. The native Core ML export
processes 32-frame windows at 700×392, using the upstream two-anchor/eight-overlap schedule and
scale/shift alignment for long clips. Overlap predictions are blended before caching, and a
clip-wide depth range avoids frame-by-frame normalization changes.

Preparation runs locally in a separate helper process; no Python, account, API key, uploads, or
runtime model downloads are needed. The source is opened for reading. Derived depth, metadata,
and Full-SBS files are stored under `~/Library/Caches/com.theanam.shoebox/Prepared3D/`, keyed by
source path, file identity, size, modification time, and model version. Changing the source
invalidates its cache. These derived files can be deleted to reclaim space; they will be recreated
when needed. Preparation can take a long time and use several GB for a feature-length video.

The prepared video uses high-quality H.264 (CRF 16), normalized constant frame timing, and an
aspect-correct 16:9 canvas for each eye, up to 1920×1080 per eye. It is a derived SDR video, not
a lossless copy or HDR-preserving conversion. Original audio packets, channel counts, subtitles,
chapters, and attachments are copied into the prepared MKV. Ordinary native subtitle overlays
are not duplicated per eye. **Off** always returns to the original source.

Subsequent plays reuse the prepared file without depth inference. Changing depth strength reuses
the depth cache and only repeats the stereo-rendering pass. Cancelling stops the worker and its
media subprocesses, removes incomplete outputs, and leaves the source intact. A finished depth
pass can be reused if cancellation happens during rendering. Live/unfinished HTTP torrent streams
must finish downloading before preprocessing. HQ mode can improve temporal consistency and
depth detail, but estimated depth, unseen-background filling, and viewing comfort still need
assessment on the glasses; artifact-free stereo is not guaranteed.

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
The build also runs native AI checks for opposite near/far eye disparity, letterboxing, upright
output, invalid depth fallback, real Core ML inference, Full-SBS GPU output, bounded queuing,
cancellation, VLC pause/resume/seeking and decoder teardown/restart. It verifies that playback
does not change its generated source file. These checks exercise the Mac GPU and Core ML runtime;
they do not replace a physical RayNeo alignment and comfort check.
Moving-silhouette regressions also verify a single foreground shape per eye, correct occlusion
ordering, preserved shape width, rejection of depth history around moving outlines, sharp
foreground/background color boundaries, and texture variation in exposed background gaps.
The HQ integration check runs the real temporal model on a generated clip and verifies overlap
and tail frame counts, per-eye aspect, frame rate, unchanged source checksums, copied surround
audio/subtitle packets, cache reuse, depth reuse across strengths, cancellation, and child cleanup.
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
