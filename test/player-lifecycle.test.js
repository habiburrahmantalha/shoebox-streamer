import assert from 'node:assert/strict';
import { test } from 'node:test';

test('closing during a play request prevents late playback, errors, and episode navigation', async () => {
  const saved = new Map(['document', 'window', 'matchMedia', 'fetch'].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  globalThis.document = { createElement: () => ({ canPlayType: () => '' }) };
  globalThis.window = {};
  globalThis.matchMedia = () => ({ matches: true });
  try {
    const { Player } = await import('../public/js/player.js');
    for (const fail of [false, true]) {
      let complete;
      globalThis.fetch = () => new Promise((resolve, reject) => { complete = fail ? reject : resolve; });
      let plays = 0;
      let navigations = 0;
      const player = Object.assign(Object.create(Player.prototype), {
        item: { id: 'video1' }, el: { classList: { add() {} } },
        root: { innerHTML: 'player' }, quality: 'auto',
        video: { play() { plays++; } },
        saveProgress() {}, teardownSource() {},
        showError() { assert.fail('A closed player must not display late errors'); },
        siblings: () => ({ next: { id: 'next' }, prev: { id: 'previous' } }),
        deps: { navigate() { navigations++; } },
      });
      const pending = player.start();
      player.destroy();
      if (fail) complete(new Error('Request failed after close'));
      else complete({ ok: true, headers: new Headers({ 'content-type': 'application/json' }), json: async () => ({ mode: 'direct', url: '/media/video1' }) });
      await pending;
      await player.start();
      player.goNext();
      player.goPrev();
      assert.equal(plays, 0);
      assert.equal(navigations, 0);
      assert.equal(player.root.innerHTML, '');
    }
  } finally {
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
});
