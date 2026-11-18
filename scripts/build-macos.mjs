import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { gunzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json')));
const cache = path.join(root, '.macos-cache');
const app = path.join(root, 'dist', 'Shoebox.app');
const contents = path.join(app, 'Contents');
const resources = path.join(contents, 'Resources');
const runtime = path.join(resources, 'runtime');
const server = path.join(resources, 'server');
const frameworks = path.join(contents, 'Frameworks');
const identity = process.env.CODE_SIGN_IDENTITY || '-';
const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64';

function run(command, args, options = {}) {
  return execFileSync(command, args, { cwd: root, stdio: 'inherit', ...options });
}
function download(url, target) {
  if (fs.existsSync(target)) return;
  console.log(`Downloading ${path.basename(target)}…`);
  run('/usr/bin/curl', ['--fail', '--location', '--retry', '2', '--max-time', '600',
                      '--silent', '--show-error', '--output', `${target}.tmp`, url]);
  fs.renameSync(`${target}.tmp`, target);
}
function checkPortable(file) {
  const output = run('/usr/bin/otool', ['-arch', architecture, '-L', file], { encoding: 'utf8', stdio: 'pipe' });
  const ownID = run('/usr/bin/otool', ['-arch', architecture, '-D', file], { encoding: 'utf8', stdio: 'pipe' }).split('\n').slice(1).join('\n').trim();
  for (const line of output.split('\n').slice(1)) {
    const dependency = line.trim().split(' (')[0];
    if (dependency && dependency !== ownID && !dependency.startsWith('/usr/lib/') && !dependency.startsWith('/System/Library/')) {
      throw new Error(`${file} depends on ${dependency}. Use a standalone binary, not a Homebrew binary.`);
    }
  }
}
function sign(file, jit = false) {
  const args = ['--force', '--sign', identity];
  if (identity !== '-') {
    args.push('--timestamp', '--options', 'runtime');
    if (jit) args.push('--entitlements', path.join(root, 'macos/Runtime.entitlements.plist'));
  }
  run('/usr/bin/codesign', [...args, file]);
}

if (process.platform !== 'darwin' || !['arm64', 'x64'].includes(process.arch)) {
  throw new Error('Build on an Apple Silicon or Intel Mac with Node.js and Xcode Command Line Tools.');
}
fs.mkdirSync(cache, { recursive: true });
// Install only the native prebuild needed by the already-installed torrent dependency.
try {
  await import('webtorrent');
} catch {
  run(process.execPath, [path.join(root, 'node_modules/prebuild-install/bin.js'), '--runtime', 'napi'], {
    cwd: path.join(root, 'node_modules/node-datachannel'),
    env: { ...process.env, npm_config_cache: cache }
  });
  // A failed build must not silently ship an app with broken torrent support.
  run(process.execPath, ['--input-type=module', '-e', "await import('webtorrent')"]);
}

const ffmpegPackage = JSON.parse(fs.readFileSync(path.join(root, 'node_modules/ffmpeg-static/package.json')));
const release = ffmpegPackage['ffmpeg-static']['binary-release-tag'];
const base = `https://github.com/eugeneware/ffmpeg-static/releases/download/${release}`;
const platform = `darwin-${process.arch}`;
for (const name of ['ffmpeg', 'ffprobe']) {
  download(`${base}/${name}-${platform}.gz`, path.join(cache, `${release}-${name}-${platform}.gz`));
}
for (const extension of ['README', 'LICENSE']) {
  download(`${base}/${platform}.${extension}`, path.join(cache, `${release}-${platform}.${extension}`));
}
const nodeLicense = path.join(path.dirname(path.dirname(process.execPath)), 'LICENSE');
const cachedNodeLicense = path.join(cache, `node-v${process.versions.node}.LICENSE`);
if (!fs.existsSync(nodeLicense)) {
  download(`https://raw.githubusercontent.com/nodejs/node/v${process.versions.node}/LICENSE`, cachedNodeLicense);
}

const vlckitVersion = '3.7.3';
const vlckitUrl = 'https://download.videolan.org/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz';
const vlckitArchive = path.join(cache, `VLCKit-${vlckitVersion}.tar.xz`);
download(vlckitUrl, vlckitArchive);
const vlckitHash = createHash('sha256').update(fs.readFileSync(vlckitArchive)).digest('hex');
if (vlckitHash !== '019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d') {
  throw new Error(`Unexpected VLCKit checksum. Remove ${vlckitArchive} and rebuild.`);
}

fs.rmSync(app, { recursive: true, force: true });
for (const directory of [runtime, server, frameworks, path.join(contents, 'MacOS')]) fs.mkdirSync(directory, { recursive: true });
const vlckit = path.join(frameworks, 'VLCKit.framework');
const extracted = fs.mkdtempSync(path.join(cache, 'vlckit-'));
try {
  const packageRoot = 'VLCKit - binary package';
  const frameworkPath = `${packageRoot}/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework`;
  const licensePath = `${packageRoot}/COPYING.txt`;
  run('/usr/bin/tar', ['-xJf', vlckitArchive, '-C', extracted, frameworkPath, licensePath]);
  run('/usr/bin/ditto', [path.join(extracted, frameworkPath), vlckit]);
  fs.copyFileSync(path.join(extracted, licensePath), path.join(resources, 'VLCKit-COPYING.txt'));
} finally {
  fs.rmSync(extracted, { recursive: true, force: true });
}
run('/usr/bin/lipo', ['-verify_arch', architecture, path.join(vlckit, 'VLCKit')]);
checkPortable(path.join(vlckit, 'VLCKit'));
for (const entry of ['bin', 'src', 'public', 'package.json', 'LICENSE', 'README.md']) {
  fs.cpSync(path.join(root, entry), path.join(server, entry), { recursive: true });
}
console.log('Bundling runtime and dependencies…');
fs.cpSync(path.join(root, 'node_modules'), path.join(server, 'node_modules'), {
  recursive: true,
  dereference: true,
  filter: (source) => {
    const parts = path.relative(path.join(root, 'node_modules'), source).split(path.sep);
    const prebuild = parts.indexOf('prebuilds');
    if (prebuild !== -1 && parts[prebuild + 1] && parts[prebuild + 1] !== platform) return false;
    return source !== path.join(root, 'node_modules/ffprobe-static/bin') &&
           source !== path.join(root, 'node_modules/.bin') &&
           source !== path.join(root, 'node_modules/ffmpeg-static/ffmpeg');
  }
});
fs.copyFileSync(process.execPath, path.join(runtime, 'node'));
fs.copyFileSync(fs.existsSync(nodeLicense) ? nodeLicense : cachedNodeLicense, path.join(runtime, 'NODE-LICENSE'));
for (const name of ['ffmpeg', 'ffprobe']) {
  fs.writeFileSync(path.join(runtime, name), gunzipSync(fs.readFileSync(path.join(cache, `${release}-${name}-${platform}.gz`))));
  fs.chmodSync(path.join(runtime, name), 0o755);
}
for (const extension of ['README', 'LICENSE']) {
  fs.copyFileSync(path.join(cache, `${release}-${platform}.${extension}`), path.join(runtime, `FFMPEG-${extension}`));
}
fs.writeFileSync(path.join(resources, 'THIRD-PARTY.txt'),
  `Node.js ${process.versions.node}: runtime/NODE-LICENSE, https://github.com/nodejs/node\n` +
  `FFmpeg/FFprobe ${release}: runtime/FFMPEG-LICENSE and runtime/FFMPEG-README\n` +
  `Build provenance: https://github.com/eugeneware/ffmpeg-static/releases/tag/${release}\n` +
  `VLCKit ${vlckitVersion}: VLCKit-COPYING.txt, ${vlckitUrl}\n` +
  `Source: https://code.videolan.org/videolan/VLCKit/-/tree/${vlckitVersion}\n` +
  'JavaScript dependencies and their license files are included in server/node_modules.\n');

const iconset = path.join(cache, 'Shoebox.iconset');
fs.mkdirSync(iconset, { recursive: true });
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    run('/usr/bin/sips', ['-z', String(size * scale), String(size * scale), path.join(root, 'public/icon-512.png'),
                         '--out', path.join(iconset, `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`)], { stdio: 'pipe' });
  }
}
run('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', path.join(resources, 'Shoebox.icns')]);
fs.writeFileSync(path.join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.theanam.shoebox</string>
<key>CFBundleName</key><string>Shoebox</string>
<key>CFBundleDisplayName</key><string>Shoebox</string>
<key>CFBundleExecutable</key><string>Shoebox</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${pkg.version}</string>
<key>CFBundleVersion</key><string>${pkg.version}</string>
<key>CFBundleIconFile</key><string>Shoebox.icns</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSDownloadsFolderUsageDescription</key><string>Shoebox plays videos from the folder you choose.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Shoebox plays videos from the folder you choose.</string>
<key>NSDesktopFolderUsageDescription</key><string>Shoebox plays videos from the folder you choose.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Shoebox plays videos from your selected external drive.</string>
</dict></plist>
`);

console.log('Compiling native macOS window…');
const subtitleScale = path.join(cache, `SubtitleScale-${architecture}.o`);
run('/usr/bin/xcrun', ['clang', '-fobjc-arc', '-target', `${architecture}-apple-macosx13.0`, '-F', frameworks,
                     '-I', path.join(vlckit, 'Headers'), '-I', path.join(vlckit, 'PrivateHeaders'),
                     '-c', path.join(root, 'macos/SubtitleScale.m'), '-o', subtitleScale]);
run('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-swift-version', '5', '-O', '-target',
                     `${architecture}-apple-macosx13.0`,
                     '-module-cache-path', path.join(cache, 'swift-modules'),
                     '-framework', 'AppKit', '-framework', 'WebKit',
                     '-F', frameworks, '-framework', 'VLCKit',
                     '-import-objc-header', path.join(root, 'macos/SubtitleScale.h'), subtitleScale,
                     path.join(root, 'macos/Shoebox.swift'), path.join(root, 'macos/OriginalPlayer.swift'),
                     '-o', path.join(contents, 'MacOS/Shoebox')]);
const nativeFiles = [];
function collect(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) collect(file);
    else if (entry.name.endsWith('.node') || entry.name.endsWith('.dylib')) nativeFiles.push(file);
  }
}
collect(path.join(server, 'node_modules'));
for (const file of [...nativeFiles, ...['node', 'ffmpeg', 'ffprobe'].map(name => path.join(runtime, name))]) {
  checkPortable(file);
  sign(file, path.basename(file) === 'node');
}
sign(vlckit);
sign(app);
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
console.log('Checking bundled playback and server shutdown…');
run(process.execPath, [path.join(root, 'scripts/check-macos.mjs'), app]);
const archive = path.join(root, 'dist', `Shoebox-${pkg.version}-macos-${process.arch}.zip`);
run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive]);
console.log(`Built ${app}\nArchive: ${archive}\n${identity === '-' ? 'Local ad-hoc signature; sign and notarize before public distribution.' : 'Developer ID signed; notarize and staple before public distribution.'}`);
