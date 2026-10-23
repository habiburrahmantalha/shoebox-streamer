import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { decide } from '../src/decide.js';
import { audioArgs, HlsManager, parseProfile, profileString } from '../src/hls.js';
import { FFMPEG, FFPROBE, probe, run } from '../src/ffmpeg.js';

const caps = { mp4: true, mse: true, video: { h264: true }, audio: { aac: true, mp3: true } };
const item = codec => ({ ext: '.mkv', probe: {
  format: 'matroska', video: { codec: 'h264', bitDepth: 8, height: 1080 },
  audio: [{ codec, channels: 6 }],
} });

test('HLS preserves compatible audio during remuxing and video conversion', () => {
  for (const codec of ['aac', 'mp3']) {
    for (const opts of [{ canRemux: true }, { quality: 720 }]) {
      const d = decide(item(codec), caps, opts);
      assert.equal(d.audioCopy, true);
      assert.equal(parseProfile(profileString(d)).audioCopy, true);
      assert.deepEqual(audioArgs(item(codec).probe, parseProfile(profileString(d))), ['-c:a', 'copy']);
    }
  }
});

test('Dolby audio uses native HLS only when the client reports support', () => {
  for (const codec of ['ac3', 'eac3']) {
    const supported = { ...caps, hlsNative: true, audio: { [codec]: true } };
    const d = decide(item(codec), supported, { canRemux: true });
    assert.equal(d.audioCopy, true);
    assert.equal(d.nativeHls, true);
    assert.equal(decide(item(codec), { ...supported, hlsNative: false }).audioCopy, undefined);
    assert.equal(decide(item(codec), caps).audioCopy, undefined);
  }
});

test('unsupported audio and playback failures retain conversion fallback', () => {
  for (const codec of ['dts', 'truehd', 'flac', 'opus']) {
    const d = decide(item(codec), { ...caps, audio: { [codec]: true } });
    assert.equal(d.audioCopy, undefined);
    assert.deepEqual(audioArgs(item(codec).probe, { audio: 0, audioCopy: true }),
      ['-c:a', 'aac', '-ac', '2', '-b:a', '320k']);
  }
  const d = decide(item('aac'), caps, { canRemux: true, forceAudioTranscode: true });
  assert.equal(d.audioCopy, undefined);
  assert.equal(profileString(d), 'c-a0');
  assert.deepEqual(parseProfile('t-720-4000-a1'), { mode: 'transcode', height: 720, kbps: 4000, audio: 1 });
  assert.equal(parseProfile('c-a0-copy-copy'), null);
  assert.deepEqual(audioArgs({ audio: [{ codec: 'flac', channels: 1 }] }, { audio: 0 }),
    ['-c:a', 'aac', '-ac', '1', '-b:a', '320k']);
  assert.deepEqual(audioArgs({ audio: [] }, { audio: 0 }), ['-an']);
});

test('direct playback still serves original supported files', () => {
  const video = item('aac');
  video.ext = '.mp4';
  video.probe.format = 'mov,mp4';
  assert.equal(decide(video, caps).mode, 'direct');
});

test('real HLS segments retain original surround AAC packets', { skip: !FFMPEG || !FFPROBE }, async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'shoebox-audio-'));
  const input = path.join(dir, 'source.ts');
  const manager = new HlsManager({ library: { getKeyframes: async it => [it.probe.start] } });
  manager.encoderOverride = 'libx264';
  const packets = async file => JSON.parse((await run(FFPROBE, ['-v', 'error', '-select_streams', 'a:0',
    '-show_packets', '-show_data_hash', 'sha256', '-show_entries', 'packet=data_hash', '-of', 'json', file])).toString()).packets;
  try {
    await run(FFMPEG, ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=24',
      '-f', 'lavfi', '-i', 'anoisesrc=sample_rate=48000:seed=1', '-t', '2',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-c:a', 'aac', '-ac', '6', '-b:a', '384k', input]);
    const description = await probe(input);
    assert.equal(description.audio[0].channels, 6);
    const original = (await packets(input)).map(p => p.data_hash);
    const media = { id: 'audio-check', input, rel: 'source.ts', size: (await fs.stat(input)).size, probe: description };
    for (const profile of ['c-a0-copy', 't-240-2000-a0-copy', 'c-a0']) {
      const session = await manager.session(media, profile, profile);
      const segment = await session.getSegment(0);
      const result = await probe(segment);
      assert.equal(result.audio[0].codec, 'aac');
      if (profile.endsWith('-copy')) {
        assert.equal(result.audio[0].channels, 6);
        const copied = (await packets(segment)).map(p => p.data_hash);
        assert.ok(copied.length > 50);
        const start = original.indexOf(copied[0]);
        assert.ok(start >= 0);
        assert.deepEqual(copied, original.slice(start, start + copied.length));
      } else assert.equal(result.audio[0].channels, 2);
      await run(FFMPEG, ['-v', 'error', '-i', segment, '-map', '0:a:0', '-f', 'null', '-']);
    }
  } finally {
    manager.shutdown();
    await fs.rm(dir, { recursive: true, force: true });
  }
});
