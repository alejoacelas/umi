// web/comments.js against the cases of Umi's app/macos/Tests/Umi/UmiCommentsTests.swift (the same
// files must come out the same), plus the preview's offsets. Run: node comments.test.js
'use strict';
const assert = require('assert');
require('../web/comments.js');
const C = globalThis.UmiComments;

const doc = '# Plan\n\nWe will ship the **new parser** on Friday.\n\n- one item\n- two items\n\n```\n{==not a comment==}{>>literal<<}\n```\n';
const range = (text, d) => { const s = d.indexOf(text); assert(s >= 0, text); return { start: s, end: s + text.length }; };
let n = 0;
const test = (name, fn) => { fn(); n++; console.log('ok  ', name); };

test('adding then deleting gives back the file', () => {
  const a = C.add(doc, 'Why Friday?', range('new parser', doc), 'user', '2026-11-04T10:00:00.000Z');
  assert.equal(a.id, 'c1');
  assert(a.text.includes('**{==new parser==}{>>Why Friday?<<}{#c1}**'));
  assert(a.text.endsWith('---\ncomments:\n  c1:\n    by: user\n    at: "2026-11-04T10:00:00.000Z"\n    umi-quote: new parser\n    umi-body: "Why Friday?"\n'));
  const r = C.reply(a.text, 'c1', 'The release train.\nSecond line.', 'AI');
  assert.equal(r.id, 'c2');
  const ts = C.threads(r.text);
  assert.equal(ts.length, 1);
  assert(ts[0].quote === 'new parser' && ts[0].line === 3 && ts[0].by === 'user');
  assert.deepEqual(ts[0].replies.map((x) => x.body), ['The release train.\nSecond line.']);
  assert.equal(C.remove(r.text, 'c1'), doc);
});

test('markup in code is literal', () => {
  assert.equal(C.threads(doc).length, 0);
  assert.equal(C.threads('Use `{==x==}{>>y<<}` to comment.\n').length, 0);
});

test('resolving and reopening', () => {
  const a = C.add(doc, 'Three?', range('two items', doc), 'user');
  const resolved = C.resolve(a.text, a.id, true, 'made it three');
  const t = C.threads(resolved)[0];
  assert(t.status === 'resolved' && t.resolved_note === 'made it three');
  assert(resolved.includes('status: resolved'));
  assert.equal(C.resolve(resolved, a.id, false), a.text);
});

test("editing a root keeps its copy in step", () => {
  const a = C.add(doc, 'First', range('one item', doc), 'user');
  const e = C.edit(a.text, a.id, 'Second');
  assert(e.includes('{>>Second<<}{#c1}') && e.includes('umi-body: Second'));
});

test('a comment whose markup is gone is detached', () => {
  const a = C.add(doc, 'Stronger verb', range('ship', doc), 'user');
  const rewritten = a.text.replace('{==ship==}{>>Stronger verb<<}{#c1}', 'release');
  const t = C.threads(rewritten)[0];
  assert(t.detached && t.body === 'Stronger verb' && t.quote === 'ship' && t.line === undefined);
  assert.equal(C.remove(rewritten, 'c1'), doc.replace('ship', 'release'));
});

test('words deleted under an anchor', () => {
  const t = C.threads('One {====}{>>gone<<}{#c1} here.\n')[0];
  assert(t.anchor_deleted && !t.detached && t.body === 'gone');
});

test("reads and answers Roughdraft's own files", () => {
  const file = 'Please revisit {==this sentence==}{>>Needs a source<<}{id="c1" by="user" at="2026-06-14T06:38:34.897Z"} and {==that==}{>>no id<<}.\nAdd {++one example++}{#s1}.\n\n---\ncomments:\n  c2:\n    body: I can add one.\n    by: AI\n    at: "2026-04-28T12:05:00.000Z"\n    re: c1\nsuggestions:\n  s1:\n    by: AI\n    at: "2026-04-28T12:10:00.000Z"\n';
  const ts = C.threads(file);
  assert.deepEqual(ts.map((t) => t.quote), ['this sentence', 'that']);
  assert(ts[0].by === 'user');
  assert.deepEqual(ts[0].replies.map((r) => r.id), ['c2']);
  assert(ts[1].id.startsWith('@'));
  const answered = C.reply(file, ts[1].id, 'ok', 'AI');
  assert(answered.text.includes('{==that==}{>>no id<<}{#c3}'));
  assert(answered.text.includes('suggestions:\n  s1:\n    by: AI'));
  assert.deepEqual(C.threads(answered.text)[1].replies.map((r) => r.body), ['ok']);
});

test('block scalars and quotes in the endmatter', () => {
  const file = "Hi {==there==}{>>x<<}{#c1}.\n\n---\ncomments:\n  c1:\n    by: user\n  c2:\n    body: |\n      line one\n      line two\n    by: 'A''s agent'\n    re: c1\n";
  const r = C.threads(file)[0].replies[0];
  assert.equal(r.body, 'line one\nline two');
  assert.equal(r.by, "A's agent");
});

test('Windows line endings stay Windows', () => {
  const crlf = 'Line one.\r\nLine two.\r\n';
  const a = C.add(crlf, 'Why?', range('two', crlf), 'user');
  assert(!a.text.replace(/\r\n/g, '').includes('\n'));
  assert.equal(C.threads(a.text).length, 1);
  assert.equal(C.remove(a.text, a.id), crlf);
});

test('placement stays in one block and out of other comments', () => {
  const s = doc.indexOf('one item\n- two');
  const a = C.add(doc, 'x', { start: s, end: s + 'one item\n- two'.length }, 'user');
  assert(a.text.includes('- {==one item==}{>>x<<}{#c1}\n- two items'));
  assert.throws(() => C.add(a.text, 'y', range('item==}', a.text), 'user'), C.Failure);
  const b = C.add(a.text, 'y', range('one item', a.text), 'user');
  assert(b.text.includes('{==one item==}{>>x<<}{#c1}{>>y<<}{#c2}'));
  assert.throws(() => C.add(doc, 'z', range('not a comment', doc), 'user'), C.Failure);
  const span = 'Run `make all` now.\n';
  assert(C.add(span, 'z', range('all', span), 'user').text.startsWith('Run {==`make all`==}'));
  assert.throws(() => C.add(doc, 'has <<} in it', range('ship', doc), 'user'), C.Failure);
  const link = 'See [the docs](https://x.y/z) here.\n';
  assert(C.add(link, 'q', range('docs](https://x.y/z) here', link), 'user').text.startsWith('See {==[the docs](https://x.y/z) here==}'));
});

test('relocating after an edit elsewhere', () => {
  const old = 'alpha beta gamma beta delta';
  assert.deepEqual(C.relocate({ start: 17, end: 21 }, old, 'intro. alpha beta gamma beta delta'), { start: 24, end: 28 });
  assert.equal(C.relocate({ start: 17, end: 21 }, old, 'alpha gamma delta'), null);
});

test('preview marks and offsets map back to the file', () => {
  const a = C.add(doc, 'Why?', range('new parser', doc), 'user');
  const p = C.preview(a.text);
  assert(!p.source.includes('comments:'));
  assert(p.source.includes('<mark class="umi-c" data-ids="c1">new parser</mark>'));
  const at = p.source.indexOf('new parser');
  assert.equal(a.text.substr(p.fileOffset(at, at + 10), 10), 'new parser');
  const fri = p.source.indexOf('Friday');
  assert.equal(a.text.substr(p.fileOffset(fri, fri + 6), 6), 'Friday');
  const resolved = C.preview(C.resolve(a.text, 'c1', true), new Set(['c1']));
  assert(resolved.source.includes('<mark class="umi-c umi-resolved" data-ids="c1">'));
  assert(C.preview('x {==hi==} {++add++} y\n').source.includes('<mark class="umi-hl">hi</mark> <ins>add</ins>'));
});

console.log(`\n${n} passed`);
