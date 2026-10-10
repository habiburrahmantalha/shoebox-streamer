import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';

const script = fs.readFileSync(new URL('../ipad/Shoebox/LibraryLoading.js', import.meta.url), 'utf8');
test('iPad shows library loading without replacing rendered content or errors', () => {
  for (const content of ['', '<main>Library</main>', '<div class="empty">Connection error</div>']) {
    const app = { innerHTML: content, hasChildNodes() { return Boolean(this.innerHTML); } };
    vm.runInNewContext(script, { document: { querySelector: () => app } });
    if (content) assert.equal(app.innerHTML, content);
    else {
      assert.match(app.innerHTML, /role="status"/);
      assert.match(app.innerHTML, /Loading your library/);
      const indicator = app.innerHTML;
      vm.runInNewContext(script, { document: { querySelector: () => app } });
      assert.equal(app.innerHTML, indicator, 'Do not duplicate the indicator');
    }
  }
  assert.doesNotThrow(() => vm.runInNewContext(script, { document: { querySelector: () => null } }));
});
