import assert from 'node:assert/strict';
import { test } from 'node:test';
import { playerBackHash } from '../public/js/util.js';

test('player closes to its underlying page without depending on browser history', () => {
  assert.equal(playerBackHash({ name: 'home' }), '#/');
  assert.equal(playerBackHash({ name: 'show', id: 'show1', season: 2 }), '#/show/show1/2');
  assert.equal(playerBackHash({ name: 'show', id: 'show1', season: 0 }), '#/show/show1/0');
  assert.equal(playerBackHash({ name: 'show', id: 'show1' }), '#/show/show1');
  assert.equal(playerBackHash({ name: 'torrents' }), '#/torrents');
  assert.equal(playerBackHash(null), '#/');
  assert.equal(playerBackHash({ name: 'watch', id: 'video1' }), '#/');
});
