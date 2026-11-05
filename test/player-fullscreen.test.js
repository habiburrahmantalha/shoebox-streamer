import assert from 'node:assert/strict';
import { test } from 'node:test';

test('Mac fullscreen preserves the video and uses native window controls', async () => {
  const globals = ['document', 'window', 'navigator', 'matchMedia', 'screen'];
  const saved = new Map(globals.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const button = {};
  const messages = [];
  globalThis.document = { createElement: () => ({ canPlayType: () => '' }) };
  globalThis.window = { webkit: { messageHandlers: { shoeboxFullscreen: { postMessage: value => messages.push(value) } } } };
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: {} });
  globalThis.matchMedia = () => ({ matches: false });
  globalThis.screen = {};
  try {
    const { Player } = await import('../public/js/player.js');
    const video = { paused: false, currentTime: 42, src: '/media/original' };
    const player = Object.assign(Object.create(Player.prototype), {
      video, el: { querySelector: () => button, requestFullscreen: () => assert.fail('Mac must not move the video into DOM fullscreen') },
      pop: { hidden: true }, deps: { onClose: () => assert.fail('Escape must exit fullscreen before closing') },
      wake() {},
    });
    // Reproduce the playback state sequence without changing the source or seeking on fullscreen.
    video.paused = true;
    video.paused = false;
    await player.toggleFullscreen();
    assert.deepEqual(messages, ['toggle']);
    assert.deepEqual(video, { paused: false, currentTime: 42, src: '/media/original' });
    window.shoeboxFullscreen = true;
    player.syncFullscreen();
    const fullscreenIcon = button.innerHTML;
    let prevented = false;
    player.onKey({ key: 'Escape', target: {}, preventDefault() { prevented = true; }, stopPropagation() {} });
    assert.equal(prevented, true);
    assert.deepEqual(messages, ['toggle', 'toggle']);
    window.shoeboxFullscreen = false;
    player.syncFullscreen();
    assert.notEqual(button.innerHTML, fullscreenIcon);

    // A browser without the Mac bridge continues to use the Fullscreen API.
    delete window.webkit;
    let requested = 0;
    player.el.requestFullscreen = async () => { requested++; };
    await player.toggleFullscreen();
    assert.equal(requested, 1);
  } finally {
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
});
