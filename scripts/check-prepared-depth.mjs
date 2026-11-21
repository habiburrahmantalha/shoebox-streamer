import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const app = path.resolve(process.argv[2]);
const resources = path.join(app, 'Contents/Resources');
const helper = path.join(app, 'Contents/MacOS/ShoeboxDepth');
const ffmpeg = path.join(resources, 'runtime/ffmpeg');
const ffprobe = path.join(resources, 'runtime/ffprobe');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'shoebox-hq-depth-'));
const cacheRoot = path.join(root, 'cache');
const source = path.join(root, 'Original 影片.mkv');
const run = (executable, args) => execFileSync(executable, args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const fingerprint = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function probe(file, stream) {
  return JSON.parse(run(ffprobe, ['-v', 'error', '-select_streams', stream, '-count_frames', '-show_streams', '-of', 'json', file])).streams[0];
}
function packets(file, stream) {
  return JSON.parse(run(ffprobe, ['-v', 'error', '-select_streams', stream, '-show_packets', '-show_data_hash', 'sha256',
    '-show_entries', 'packet=data_hash', '-of', 'json', file])).packets.map(packet => packet.data_hash);
}
async function prepare(file, strength, cancel = false) {
  const process = spawn(helper, [file, String(strength), resources, cacheRoot], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '', cancelling = false, children = [];
  process.stdout.on('data', data => {
    stdout += data;
    if (cancel && !cancelling && stdout.includes('Preparing temporal depth')) {
      cancelling = true;
      try { children = run('/usr/bin/pgrep', ['-P', String(process.pid)]).trim().split('\n').map(Number).filter(Boolean); } catch {}
      process.kill('SIGTERM');
    }
  });
  process.stderr.on('data', data => { stderr += data; });
  const code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { process.kill('SIGKILL'); reject(new Error('Temporal preparation timed out')); }, 300000);
    process.once('error', error => { clearTimeout(timer); reject(error); });
    process.once('close', value => { clearTimeout(timer); resolve(value); });
  });
  if (cancel) {
    assert(cancelling && code === 130, `Cancellation failed: ${code}, ${stderr}`);
    for (let attempt = 0; attempt < 100; attempt++) {
      children = children.filter(pid => { try { globalThis.process.kill(pid, 0); return true; } catch { return false; } });
      if (!children.length) break;
      await delay(50);
    }
    assert.equal(children.length, 0, 'Cancelled preparation left media helper processes running');
    return;
  }
  if (code !== 0) {
    const logs = fs.existsSync(cacheRoot) ? fs.readdirSync(cacheRoot).map(key => {
      try { return fs.readFileSync(path.join(cacheRoot, key, 'preparation.log'), 'utf8').slice(-2400); } catch { return ''; }
    }).join('\n') : '';
    throw new Error(`Preparation failed (${code}): ${stderr}\n${logs}`);
  }
  assert(stdout.includes('High-quality 3D is ready'));
}

try {
  const subtitle = path.join(root, 'sample.srt');
  fs.writeFileSync(subtitle, '1\n00:00:01,000 --> 00:00:02,000\nOriginal subtitle\n');
  run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=24000/1001',
    '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=5.1', '-i', subtitle, '-map', '0:v', '-map', '1:a', '-map', '2:s',
    '-frames:v', '64', '-t', String(64 * 1001 / 24000), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '320k', '-c:s', 'srt', source]);
  const original = fingerprint(source);
  await prepare(source, 0.032);
  assert.equal(fingerprint(source), original, 'Preprocessing changed the original video');
  const directory = path.join(cacheRoot, fs.readdirSync(cacheRoot)[0]);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json')));
  assert.equal(manifest.frames, 64, 'Overlapping/padded temporal windows changed the frame count');
  const balanced = path.join(directory, 'sbs-320.mkv');
  const output = probe(balanced, 'v:0');
  assert.equal(Number(output.nb_read_frames), 64);
  assert.equal(output.width / (2 * output.height), 16 / 9, 'Each eye needs a 16:9 canvas, including for 4:3 sources');
  const [numerator, denominator] = output.avg_frame_rate.split('/').map(Number);
  assert(Math.abs(numerator / denominator - 24000 / 1001) < 0.001, 'Prepared playback frame rate drifted');
  assert.equal(probe(balanced, 'a:0').channels, 6, 'Surround channels were lost');
  assert.deepEqual(packets(balanced, 'a:0'), packets(source, 'a:0'), 'Audio was re-encoded');
  assert.deepEqual(packets(balanced, 's:0'), packets(source, 's:0'), 'Subtitle packets were changed');
  const depth = path.join(directory, 'depth.mkv');
  const depthTime = fs.statSync(depth).mtimeMs, playbackTime = fs.statSync(balanced).mtimeMs;
  await prepare(source, 0.032);
  assert.equal(fs.statSync(balanced).mtimeMs, playbackTime, 'Ready results should be reused');
  await prepare(source, 0.048);
  assert.equal(fs.statSync(depth).mtimeMs, depthTime, 'Changing strength must reuse prepared temporal depth');
  assert(fs.existsSync(path.join(directory, 'sbs-480.mkv')));
  const longer = path.join(root, 'Cancel me.mkv');
  run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=24', '-t', '8', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', longer]);
  const cancelOriginal = fingerprint(longer);
  await prepare(longer, 0.032, true);
  assert.equal(fingerprint(longer), cancelOriginal, 'Cancellation changed its source');
  for (const key of fs.readdirSync(cacheRoot)) {
    assert(!fs.readdirSync(path.join(cacheRoot, key)).some(name => name.endsWith('.partial.mkv')), 'Cancelled preparation left partial media files');
  }
  console.log('HQ preprocessing passed: real temporal model, overlap/tail frames, source checksum, per-eye aspect, frame rate, original surround audio/subtitles, cache reuse, strength re-render, cancellation and child cleanup.');
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
