# iPad app

Shoebox for iPad is a SwiftUI connection screen and WKWebView player. It uses the existing
Mac HTTP server, library API, direct media streams, and HLS conversion. Videos and FFmpeg
stay on the Mac; the iPad app does not run a server. Requires iPadOS 17+.

## Start the Mac server

From the repository:

```sh
./scripts/start-ipad-server.command "/Volumes/Netac/Download"
# Optional second argument chooses a different port:
./scripts/start-ipad-server.command "$HOME/Movies" 7173
```

Alternatively, double-click the `.command` file in Finder and paste the full folder path,
without shell quotes. The launcher validates the folder and port. It reuses `dist/Shoebox.app`
first, then `/Applications/Shoebox.app`, including their bundled Node and media tools.
Without a bundle, install Node.js and run `npm ci` in this checkout first.
Rebuild the macOS bundle with `npm run build:macos` to use the latest server changes.

The launcher binds all IPv4 interfaces, prints LAN URLs and a QR code, and prevents idle
system sleep while running. Keep the Terminal open, the Mac connected to Wi-Fi, and the
laptop lid open. Press Control-C to stop sharing. The standalone desktop app remains
local to the Mac on port 7172 and can run alongside this server on port 7171.

This is trusted-network sharing: anyone who can reach the port can access the library and
its torrent controls. HTTP traffic is unencrypted. Do not forward the port through your router
or expose it publicly. The script does not change your firewall or router settings.

## Install on an iPad

1. Install full Xcode with its iOS platform support on the Mac.
2. Open `ipad/Shoebox.xcodeproj`.
3. In Xcode Settings → Apple Accounts, sign in with `habiburrahmantahla@gmail.com`.
4. In the Shoebox target's Signing & Capabilities, select the team belonging to that account. Change the bundle
   identifier if your account needs a unique identifier.
5. Connect and trust the iPad, enable Developer Mode if requested, select it as the run
   destination, and click Run. No signing account is selected or stored by this repository.
6. Start the Mac server and allow Shoebox local network access on the iPad. Under
   **Nearby servers**, tap **Connect to Shoebox (…)**. The app discovers the Mac's published
   Bonjour service and resolves its host and port automatically.
7. If no server appears, tap **Refresh servers**, or enter the printed LAN URL, such as
   `http://192.168.1.10:7171`, under **Manual server address** and tap Connect.

Discovery runs while the connection screen is visible and pauses while connected or in the
background. Returning to the screen resumes discovery. Services that leave disappear from
the list. Only HTTP services named `Shoebox (…)` are listed, matching the existing Mac
server's advertisements. This label is not authentication; choose a Mac you trust.
Bonjour/mDNS must be enabled in the Mac server settings, and the network must allow
multicast and communication between devices. The Mac desktop app alone is loopback-only
and is not discoverable; start the sharing script.

This fork's app developer contact is `habiburrahmantahla@gmail.com`; the original project
author remains credited in `package.json` and `LICENSE`. The iPad's developer trust identity
comes from Apple's signing certificate, not the app's contact text. To change that identity,
sign and reinstall from Xcode using the account above. Trust only the identity matching your
selected team in Settings → General → VPN & Device Management.

A personal Apple account can install development builds subject to Apple's provisioning
limits; App Store/TestFlight distribution requires the appropriate developer membership
and release setup. See Apple's [device setup instructions](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).

The app remembers the entered address. Change Mac disconnects the player and returns to
the connection screen. Reload retries the current server. The Mac's IP can change between
networks; use the current printed address. External links open in the appropriate installed
app. Native download management and offline playback are not included in this first client;
use Safari for downloadable playlists/files.

## Build and checks

```sh
npm run build:ipad
npm test
node scripts/check-ipad-server.mjs
bash scripts/check-ipad-discovery.sh
```

The iPad build checks address parsing and origin restrictions, then builds an unsigned
simulator app at `dist/ipad/Build/Products/Debug-iphonesimulator/Shoebox.app`. It does not
install on a physical iPad or choose an Apple Developer account.
The server check starts the launcher with a temporary empty library on a temporary port,
checks the library/API/player assets, and stops it. It briefly opens that empty library to
the local network; no personal video folder is used.
The discovery check briefly publishes a uniquely named test HTTP service with macOS
`dns-sd`, then uses the same Swift discovery class to check finding, host/port resolution,
deduplication, removal, and stopping. It does not serve or share files. The app declares
`_http._tcp` in `NSBonjourServices` as required by
[Apple's local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

For an unsigned device compilation check:

```sh
xcodebuild -project ipad/Shoebox.xcodeproj -scheme Shoebox \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath dist/ipad-device CODE_SIGNING_ALLOWED=NO build
```

Before release, test on a physical iPad: direct and transcoded playback, seeking, rotation,
fullscreen/PiP, reconnect after sleep, local-network permissions, subtitles, and external players.
Simulator compilation alone does not verify those behaviors.

## Connection problems

- First open the printed LAN URL in Safari on the iPad. Do not enter `localhost` or `127.0.0.1`;
  those refer to the iPad itself.
- Use the same Wi-Fi and disable guest/client isolation if your router separates devices.
- Allow incoming connections for the server runtime in the Mac firewall if requested.
- Check iPad Settings for local network permissions if access was denied.
- If the port is occupied, stop the other server or pass another port to the script.
- If the Mac sleeps, loses its drive, or changes network, restore it and tap Reload.
