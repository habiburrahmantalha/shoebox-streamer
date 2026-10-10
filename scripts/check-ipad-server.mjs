import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

assert.equal(process.platform, 'darwin', 'Run this launcher check on macOS');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'shoebox-ipad-check-'));
const probe = net.createServer();
await new Promise((resolve, reject) => { probe.once('error', reject); probe.listen(0, '127.0.0.1', resolve); });
const port = probe.address().port;
await new Promise(resolve => probe.close(resolve));
const child = spawn('bash', [path.join(root, 'scripts/start-ipad-server.command'), folder, String(port)], {
  detached: true,
  env: { ...process.env, SHOEBOX_CONFIG: path.join(folder, 'no-config.json') },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let output = '';
child.stdout.on('data', data => { output += data; });
child.stderr.on('data', data => { output += data; });
let exited = false;
const stopped = new Promise(resolve => child.once('exit', code => { exited = true; resolve(code); }));
const base = `http://127.0.0.1:${port}`;
try {
  let info;
  for (let attempt = 0; attempt < 100; attempt++) {
    assert(!exited, `Server exited early: ${output}`);
    try {
      const response = await fetch(`${base}/api/info`, { signal: AbortSignal.timeout(500) });
      if (response.ok) { info = await response.json(); break; }
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  assert(info, `Server did not become ready: ${output}`);
  assert.equal(await fs.realpath(info.root), await fs.realpath(folder));
  assert.equal(info.port, port);
  assert(info.urls.some(url => url.endsWith(`:${port}`)), 'Server must advertise a LAN address');
  const library = await (await fetch(`${base}/api/library`)).json();
  assert.equal(library.items.length, 0);
  for (const route of ['/', '/js/player.js', '/js/app.js']) {
    assert.equal((await fetch(base + route)).status, 200, route);
  }
  console.log('iPad launcher: LAN addresses, API, empty library, and player assets passed');
} finally {
  if (!exited) process.kill(-child.pid, 'SIGINT');
  let timer;
  const code = await Promise.race([stopped, new Promise(resolve => { timer = setTimeout(() => resolve('timeout'), 8000); })]);
  clearTimeout(timer);
  if (code === 'timeout') { process.kill(-child.pid, 'SIGKILL'); await stopped; }
  await fs.rm(folder, { recursive: true, force: true });
  assert.notEqual(code, 'timeout', 'Server must stop after Control-C');
}
await assert.rejects(fetch(`${base}/api/info`, { signal: AbortSignal.timeout(1000) }));
console.log('iPad launcher: shutdown passed');
