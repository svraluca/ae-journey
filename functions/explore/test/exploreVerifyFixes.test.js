'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  stagedVerifyUrls,
  familyPaths,
  INTERACTIVE_DEADLINE_MS,
  pastDeadline,
} = require('../getExploreProcedurePrices');

test('cached procedure URLs are staged before SERP', () => {
  const stages = stagedVerifyUrls({
    base: 'https://clinic.example',
    host: 'clinic.example',
    procedure: 'Botox anti-wrinkle injection',
    cachedSuccess: ['https://clinic.example/botox-menu'],
    serpUrls: ['https://clinic.example/blog/botox-cost'],
  });
  assert.deepEqual(stages.siteUrlCache, ['https://clinic.example/botox-menu']);
  assert.ok(stages.familyPaths.some((u) => u.endsWith('/botox')));
  assert.ok(stages.officialPage.includes('https://clinic.example'));
  assert.ok(familyPaths('Botox anti-wrinkle injection').includes('/botox'));
  const order = ['siteUrlCache', 'familyPaths', 'officialPage', 'serp'];
  assert.deepEqual(Object.keys(stages), order);
});

test('interactive deadline is 8 seconds', () => {
  assert.equal(INTERACTIVE_DEADLINE_MS, 8000);
  assert.equal(pastDeadline(Date.now() - 1, 0), true);
  assert.equal(pastDeadline(Date.now() + 5000, 400), false);
});
