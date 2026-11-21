import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cache = path.join(root, '.macos-cache');
fs.mkdirSync(cache, { recursive: true });
const revision = '4f5ae23172ba60fd7bc11ef671cca678842c7072';
const model = 'vda-small-32-700x392-25687536-v1';
const packagePath = path.join(cache, 'VideoDepthAnythingSmall32.mlpackage');
const provenance = path.join(cache, 'video-depth-export.json');
function run(command, args) { return execFileSync(command, args, { cwd: root, stdio: 'inherit' }); }
function download(url, file, hash) {
  if (!fs.existsSync(file)) {
    run('/usr/bin/curl', ['-fL', '--retry', '2', '--max-time', '600', '-sS', url, '-o', `${file}.tmp`]);
    fs.renameSync(`${file}.tmp`, file);
  }
  if (createHash('sha256').update(fs.readFileSync(file)).digest('hex') !== hash) throw new Error(`Unexpected checksum: ${file}`);
}
download(`https://codeload.github.com/DepthAnything/Video-Depth-Anything/tar.gz/${revision}`,
  path.join(cache, 'video-depth-anything.tar.gz'), 'c6b168840ef9c3bea586eb60cda474d01b840843cc68dee58eee36e11ab6c087');
download('https://huggingface.co/depth-anything/Video-Depth-Anything-Small/resolve/256875362cff76724b920335dfb4b29dd611f66e/video_depth_anything_vits.pth',
  path.join(cache, 'video_depth_anything_vits.pth'), '13379300b739e659f076a59d52e9801bd8d38c541a7e71f73bbca4dcfb013609');
const source = path.join(cache, 'video-depth-anything');
fs.mkdirSync(source, { recursive: true });
run('/usr/bin/tar', ['-xzf', path.join(cache, 'video-depth-anything.tar.gz'), '-C', source, '--strip-components=1']);
let metadata;
try { metadata = JSON.parse(fs.readFileSync(provenance)); } catch {}
if (metadata?.model !== model || !fs.existsSync(packagePath)) {
  const environment = path.join(cache, 'depth-convert-env');
  const python = path.join(environment, 'bin/python');
  if (!fs.existsSync(python)) run(process.env.SHOEBOX_MODEL_PYTHON || 'python3.11', ['-m', 'venv', environment]);
  run(python, ['-m', 'pip', 'install', '-r', path.join(root, 'macos/video-depth-requirements.txt')]);
  run(python, [path.join(root, 'scripts/convert-video-depth.py')]);
}
export { packagePath, source };
