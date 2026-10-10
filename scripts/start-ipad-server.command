#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [video-folder] [port (default 7171)]"
  echo "Without a folder argument, prompts for one. Shares that folder on your local network."
  exit 0
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Run this script on macOS." >&2
  exit 1
fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
folder=${1:-}
if [[ -z "$folder" ]]; then
  read -r -p "Video folder to share (paste its full path): " folder
fi
if [[ ! -d "$folder" || ! -r "$folder" ]]; then
  echo "Not a readable folder: $folder" >&2
  exit 1
fi
folder=$(cd -- "$folder" && pwd)
port=${2:-7171}
if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
  echo "Port must be a number from 1 to 65535." >&2
  exit 1
fi
port=$((10#$port))

# Reuse the standalone app's runtime so this also works without Node on PATH.
resources=""
for app in "$repo/dist/Shoebox.app" "/Applications/Shoebox.app"; do
  if [[ -x "$app/Contents/Resources/runtime/node" && -f "$app/Contents/Resources/server/bin/shoebox.js" ]]; then
    resources="$app/Contents/Resources"
    break
  fi
done
if [[ -n "$resources" ]]; then
  node="$resources/runtime/node"
  server="$resources/server/bin/shoebox.js"
  export SHOEBOX_FFMPEG="$resources/runtime/ffmpeg"
  export SHOEBOX_FFPROBE="$resources/runtime/ffprobe"
else
  node=$(command -v node || true)
  server="$repo/bin/shoebox.js"
  if [[ -z "$node" || ! -d "$repo/node_modules" ]]; then
    echo "Build Shoebox.app first, or install Node.js and run npm ci in $repo." >&2
    exit 1
  fi
fi
unset SHOEBOX_DESKTOP_READY NODE_OPTIONS NODE_PATH
echo "Sharing: $folder"
echo "Devices on your network can access this library without a password. Use trusted Wi-Fi."
echo "On iPad, enter an 'On your LAN' address printed below in Shoebox or Safari."
echo "Keep this Terminal open. Press Control-C to stop sharing."
exec /usr/bin/caffeinate -i "$node" "$server" "$folder" --host 0.0.0.0 --port "$port"
