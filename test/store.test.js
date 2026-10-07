import assert from 'node:assert/strict';
import { test } from 'node:test';

test('folder switching isolates watch history and migrates existing progress once', async () => {
  const values = new Map([['shoebox:progress', JSON.stringify({ same: { t: 30, d: 100 } })]]);
  globalThis.localStorage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
  try {
    const store = await import('../public/js/store.js');
    store.useLibrary('/Movies');
    assert.equal(store.getProgress('same').t, 30);
    store.useLibrary('/External/Movies');
    assert.equal(store.getProgress('same'), undefined);
    store.setProgress('same', 80, 100);
    store.useLibrary('/Movies');
    assert.equal(store.getProgress('same').t, 30);
    store.useLibrary('/External/Movies');
    assert.equal(store.getProgress('same').t, 80);
    store.useLibrary('/New');
    assert.equal(store.getProgress('same'), undefined);
    globalThis.localStorage.getItem = () => { throw new Error('Storage denied'); };
    globalThis.localStorage.setItem = () => { throw new Error('Storage denied'); };
    assert.doesNotThrow(() => store.useLibrary('/Unavailable'));
    assert.doesNotThrow(() => store.setProgress('same', 20, 100));
  } finally {
    delete globalThis.localStorage;
  }
});
