// node next/app/tests/session_switcher.test.js
'use strict';
const assert = require('node:assert/strict');
global.window = global;
require('../web/model.js');
Umi.status = require('../web/status.js');
const M = Umi.model, S = Umi.state;

const desk = '/work/desk', umi = '/work/umi';
const current = M.newTab(M.newPane({ session: 'shell', cwd: desk }));
const other = M.newTab(M.newPane({ session: 'question', cwd: umi }));
M.load({ layout: { tabs: [current, other], activeTab: current.id } });
const session = (id, extra = {}) => ({ id, name: id, project: desk, folder: desk, alive: true, state: 'waiting', ...extra });
const sessions = [
  session('shell'),
  session('question', { project: umi, agent: { event: 'PermissionRequest', ts: 9 } }),
  session('finished', { agent: { event: 'Stop', reply: 'Status: done', ts: 8 } }),
  session('build', { state: 'busy' }),
  session('nap', { state: 'busy', project: umi }),
  session('hook-failed', { docket: { state: 'failed', error: 'hook failed' } }),
  session('on-docket', { docket: { state: 'on' } }),
  session('script', { by: 'agent' }),
  session('dead', { alive: false }),
];
M.sessions(sessions);
M.rename('question', 'Choose an icon');
M.snooze('nap', 1800);
const ids = (ss) => ss.map((s) => s.id);
let groups = M.switcherGroups();
assert.deepEqual(ids(groups.needs), ['question', 'hook-failed']);
assert.deepEqual(ids(groups.busy), ['build']);
assert.deepEqual(ids(groups.available), ['finished', 'shell']);
assert.deepEqual(ids(groups.snoozed), ['nap']);
assert.deepEqual(ids(groups.docketed), ['on-docket']);
assert.deepEqual(ids(M.switcherGroups('UMI icon').needs), ['question']);
assert.deepEqual(ids(M.switcherGroups('UMI').snoozed), ['nap']);
assert.deepEqual(M.switcherGroups('no match'), { needs: [], busy: [], available: [], snoozed: [], docketed: [] });
assert.deepEqual(M.review().flatMap((g) => ids(g.items)).sort(), ids(groups.needs).sort());
M.sessions([...sessions].reverse());
assert.deepEqual(M.switcherGroups(), groups);

// Unchanged session data is enough for a timed snooze to expire on the next daemon poll.
S.layout.meta.sessions.nap.snooze.until = Date.now() / 1000 - 1;
M.sessions(sessions);
assert.equal(M.switcherGroups().needs[0].id, 'nap');
// A turn ending wakes a snooze even when the reply says done.
M.snooze('finished');
sessions.find((s) => s.id === 'finished').agent.ts = S.layout.meta.sessions.finished.snooze.since + 1;
M.sessions(sessions);
assert.ok(ids(M.switcherGroups().needs).includes('finished'));

// The first native paneInfo has not arrived yet. The other tab's pane still owns its session.
const original = other.root;
const splitPicker = Umi.actions.splitRight();
M.switchFromPicker('question', splitPicker.id);
assert.equal(M.activeTab(), other);
assert.equal(M.focusedPane(), original);
assert.equal(current.root.session, 'shell');
assert.equal(M.findPane(splitPicker.id), null);

// A hidden session occupies the rightmost picker slot, and its former tab forgets its hidden chip.
M.focusPane(current.root.id);
other.hidden = ['nap'];
const hiddenPicker = Umi.actions.splitRight();
M.switchFromPicker('nap', hiddenPicker.id);
assert.equal(current.root.b, M.focusedPane());
assert.equal(current.root.b.attach, 'nap');
assert.equal(M.findPane(hiddenPicker.id), null);
assert.equal(S.layout.meta.sessions.nap.snooze, undefined);
assert.equal(other.hidden, undefined);

// A tab whose only pane is a picker keeps its identity when visiting another tab.
const pickerTab = M.addTab(M.newPicker(desk, desk));
pickerTab.name = 'Inbox';
M.switchFromPicker('question', pickerTab.focused);
assert.equal(M.activeTab(), other);
assert.ok(S.layout.tabs.includes(pickerTab));

// A dead docket entry cannot be attached. Its hook error stays available in the picker.
const failed = sessions.find((s) => s.id === 'hook-failed');
failed.alive = false;
const deadPicker = Umi.actions.splitRight();
assert.equal(M.switchFromPicker(failed.id, deadPicker.id), 'hook failed');
assert.equal(M.focusedPane(), deadPicker);
assert.equal(failed.docket.state, 'failed');
// If the agent's transcript survived, selecting the entry can resume it.
failed.kind = 'codex';
failed.agent = { event: 'Stop', agentSession: 'transcript' };
const messages = [];
Umi.bridge = { post: (msg) => messages.push(msg) };
M.switchFromPicker(failed.id, deadPicker.id);
assert.equal(M.focusedPane().start.cmd, 'codex resume transcript');
assert.equal(M.focusedPane().start.cwd, desk);
assert.deepEqual(messages, [{ type: 'undocket', session: failed.id }]);

M.addTab(M.newPicker(umi + '/next', umi));
const nestedPicker = Umi.actions.splitRight();
assert.equal(nestedPicker.cwd, umi + '/next');
assert.equal(nestedPicker.picker.project, umi);

Umi.views = {};
for (const [id, waiting] of [
  ['build', { state: 'waiting' }],
  ['asking', { state: 'waiting', agent: { event: 'PermissionRequest' } }],
  ['done', { state: 'waiting', agent: { event: 'Stop', reply: 'Status: done' } }],
]) {
  const s = session(id, { state: 'busy' });
  M.sessions([...sessions.filter((entry) => entry.id !== id), s]);
  M.appendPane(pickerTab, M.newPane({ session: id, cwd: umi }));
  const paneId = pickerTab.focused;
  Umi.actions.hidePane();
  assert.equal(M.findPane(paneId), null);
  assert.ok(M.hiddenOf(pickerTab).includes(id));
  assert.ok(ids(M.switcherGroups().snoozed).includes(id));
  Object.assign(s, waiting);
  M.sessions([...sessions.filter((entry) => entry.id !== id), s]);
  assert.ok(ids(M.switcherGroups().needs).includes(id));
  assert.equal(M.paneOfSession(id), undefined);
}

M.focusPane(current.root.a.id);
Umi.actions.hidePane();
assert.equal(M.paneOfSession('shell'), undefined);
assert.ok(ids(M.switcherGroups().available).includes('shell'));
