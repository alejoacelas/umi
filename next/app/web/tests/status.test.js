// node next/app/web/tests/status.test.js
'use strict';
const assert = require('node:assert/strict');
const { parseStatus, isDone } = require('../status.js');

const cases = [
  ['Fixed it.\n\nStatus: done', { kind: 'done', detail: '' }],
  ['Fixed it.\n\n**Status: done**', { kind: 'done', detail: '' }],
  ['**Status:** done', { kind: 'done', detail: '' }],
  ['- Status: waiting on you: approve the deploy', { kind: 'waiting', detail: 'approve the deploy' }],
  ['Notes\n* status: Waiting on you: pick a name', { kind: 'waiting', detail: 'pick a name' }],
  ['`Status: done, pending verification: CI run at 14:00`', { kind: 'pending', detail: 'CI run at 14:00' }],
  ['Status: in progress: tests next', { kind: 'progress', detail: 'tests next' }],
  ['_Status: done._', { kind: 'done', detail: '' }],
  ['> Status: done', { kind: 'done', detail: '' }],
  ['1. Status: done', { kind: 'done', detail: '' }],
  ['Status: waiting on you: X\nmore text\nStatus: done', { kind: 'done', detail: '' }],  // the last one wins
  ['Status: done\nthen I kept going.\nStatus: in progress: refactor next', { kind: 'progress', detail: 'refactor next' }],
  ['All good, nothing else.', null],
  ['The status: is unclear', null],               // not at the start of a line
  ['', null],
  [null, null],
  ['Status: blocked', { kind: 'other', detail: 'blocked' }],
];
let n = 0;
for (const [text, want] of cases) {
  assert.deepEqual(parseStatus(text), want, JSON.stringify(text));
  n++;
}
assert.equal(isDone(parseStatus('**Status: done**')), true);
assert.equal(isDone(parseStatus('Status: done, pending verification: X')), true);
assert.equal(isDone(parseStatus('- Status: waiting on you: X')), false);
assert.equal(isDone(parseStatus('no status')), false);
console.log(`status.test.js: ${n + 4} checks passed`);
