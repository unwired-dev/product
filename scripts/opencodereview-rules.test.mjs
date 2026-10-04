import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

import config from '../.opencodereview/rule.json' with { type: 'json' };

const root = new URL('../', import.meta.url);
const { rules } = config;
const common = '.opencodereview/rules/common.md';

// Open Code Review resolves an unreadable rule file to no project rule and only warns.
test('Open Code Review rule files are readable and require the common checklist', async () => {
  assert.equal(rules.at(-1).path, '**/*', 'The fallback entry must be last.');
  assert.equal(rules.at(-1).rule, common);
  for (const { path, rule } of rules) {
    assert.match(rule, /^\.opencodereview\/rules\/[a-z-]+\.md$/u);
    const body = await readFile(new URL(rule, root), 'utf8');
    assert.ok(body.trim().length > 0, `${rule} is empty.`);
    if (rule !== common) {
      assert.ok(
        body.split('\n\n', 1)[0].includes(common),
        `${rule} (${path}) must require ${common} in its first paragraph.`,
      );
    }
  }
});
