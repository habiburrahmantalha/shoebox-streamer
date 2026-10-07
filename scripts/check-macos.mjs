// Run with: node scripts/check-macos.mjs [dist/Shoebox.app]
// Uses a temporary library and only the binaries/dependencies inside the app.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import http from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const app = path.resolve(process.argv[2] || path.join(root, 'dist/Shoebox.app'));
const resources = path.join(app, 'Contents/Resources');
const runtime = path.join(resources, 'runtime');
const server = path.join(resources, 'server');
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'shoebox-macos-'));
const library = path.join(temporary, 'Video folder 日本語');
const readyFile = path.join(temporary, 'ready.json');
await fs.mkdir(library);
const env = { ...process.env, PATH: '/usr/bin:/bin',
  SHOEBOX_FFMPEG: path.join(runtime, 'ffmpeg'), SHOEBOX_FFPROBE: path.join(runtime, 'ffprobe'),
  SHOEBOX_CONFIG: path.join(temporary, 'config.json'), SHOEBOX_DESKTOP_READY: readyFile };
delete env.NODE_OPTIONS;
delete env.NODE_PATH;
let child;
let log = '';
try {
  execFileSync(env.SHOEBOX_FFMPEG, ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
    '-i', 'testsrc2=size=640x360:rate=24', '-t', '2', '-c:v', 'libx264', '-preset', 'ultrafast',
    '-pix_fmt', 'yuv420p', path.join(library, 'Sample.mp4')], { env });
  const probe = JSON.parse(execFileSync(env.SHOEBOX_FFPROBE, ['-v', 'error', '-show_format',
    '-of', 'json', path.join(library, 'Sample.mp4')], { env, encoding: 'utf8' }));
  assert.ok(Number(probe.format.duration) >= 2);
  child = spawn(path.join(runtime, 'node'), [path.join(server, 'bin/shoebox.js'), library,
    '--host', '127.0.0.1', '--port', '0', '--no-mdns', '--offline', '--no-watch'],
    { cwd: server, env, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', data => { log += data; });
  child.stderr.on('data', data => { log += data; });
  let launchError;
  child.on('error', error => { launchError = error; });
  const deadline = Date.now() + 30000;
  let ready;
  while (!ready && Date.now() < deadline) {
    assert.equal(launchError, undefined);
    assert.equal(child.exitCode, null, log);
    try { ready = JSON.parse(await fs.readFile(readyFile, 'utf8')); } catch {}
    if (!ready) await delay(100);
  }
  assert.ok(ready?.port > 0, `Server did not become ready: ${log}`);
  assert.equal(ready.root, library);
  const base = `http://127.0.0.1:${ready.port}`;
  const request = async (route, options) => {
    const response = await fetch(base + route, { ...options, signal: AbortSignal.timeout(15000) });
    assert.equal(response.status, 200, `${route}: ${await response.clone().text()}`);
    return response;
  };
  assert.match(await (await request('/')).text(), /Shoebox/);
  assert.match(await (await request('/js/app.js')).text(), /loadLibrary/);
  assert.ok((await request('/vendor/hls.min.js')).headers.get('content-type').includes('javascript'));
  let info;
  do {
    info = await (await request('/api/info')).json();
    if (!info.torrents.available) await delay(100);
  } while (!info.torrents.available && Date.now() < deadline);
  assert.deepEqual(info.urls, []);
  assert.equal(info.mdns, null);
  assert.equal(info.torrents.available, true, info.torrents.error);
  for (const headers of [{ Origin: 'https://example.com' }, { Host: 'example.com' }, { 'Sec-Fetch-Site': 'cross-site' }]) {
    const status = await new Promise((resolve, reject) => {
      const request = http.get(`${base}/api/library`, { headers }, response => {
        response.resume();
        resolve(response.statusCode);
      });
      request.on('error', reject);
      request.setTimeout(15000, () => request.destroy(new Error('Request timed out')));
    });
    assert.equal(status, 403, JSON.stringify(headers));
  }
  const snapshot = await (await request('/api/library')).json();
  assert.equal(snapshot.items.length, 1);
  const item = snapshot.items[0];
  const range = await fetch(`${base}/media/${item.id}/Sample.mp4`, { headers: { Range: 'bytes=0-99' }, signal: AbortSignal.timeout(15000) });
  assert.equal(range.status, 206);
  assert.equal((await range.arrayBuffer()).byteLength, 100);
  const playback = await (await request(`/api/play/${item.id}`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ client: 'macos-smoke', caps: { mp4: true, video: { h264: true }, audio: { aac: true } } })
  })).json();
  assert.equal(playback.mode, 'direct');
  const converted = await (await request(`/api/play/${item.id}`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ client: 'macos-smoke', caps: { hlsNative: true, video: {}, audio: {} } })
  })).json();
  assert.equal(converted.mode, 'transcode');
  const playlist = await (await request(converted.url)).text();
  assert.match(playlist, /#EXTM3U/);
  const segment = playlist.split('\n').find(line => line && !line.startsWith('#'));
  assert.ok(segment);
  const segmentURL = new URL(segment, base + converted.url);
  assert.ok((await (await request(segmentURL.pathname)).arrayBuffer()).byteLength >= 188);
  const closed = once(child, 'exit');
  child.kill('SIGTERM');
  const result = await Promise.race([closed, delay(6000).then(() => { throw new Error('Server did not stop'); })]);
  assert.equal(result[0], 0, log);
  await assert.rejects(fetch(base, { signal: AbortSignal.timeout(1000) }));
  console.log('macOS bundle check passed: isolated runtime, Unicode folder, media probing, local-only API, torrents, direct playback, HLS transcoding, byte ranges, shutdown.');
} finally {
  if (child && child.exitCode === null) child.kill('SIGKILL');
  await fs.rm(temporary, { recursive: true, force: true });
}
