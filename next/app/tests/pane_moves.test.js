// node next/app/tests/pane_moves.test.js
'use strict';
const assert = require('node:assert/strict');
global.window = global;
require('../web/model.js');
require('../web/arrange.js');

const M = Umi.model;
function row(widths) {
  const panes = widths.map(() => M.newPane());
  let root = panes[0], total = widths[0];
  for (let i = 1; i < panes.length; i++) {
    root = { type: 'split', dir: 'row', ratio: total / (total + widths[i]), a: root, b: panes[i] };
    total += widths[i];
  }
  return { ...M.newTab(), root, focused: panes[0].id };
}
function widths(node, width = 1) {
  if (node.type === 'pane') return [Math.round(width * 100)];
  return [...widths(node.a, width * node.ratio), ...widths(node.b, width * (1 - node.ratio))];
}

for (const move of ['paneToTabUp', 'paneToTabDown', 'moveToNewTab']) {
  const tab = row([1, 1, 1, 1]), moved = tab.focused;
  Umi.state.layout = { tabs: [tab], activeTab: tab.id };
  Umi.actions[move]();
  assert.deepEqual(widths(tab.root), [33, 33, 33]);
  assert.equal(M.activeTab(), Umi.state.layout.tabs[1]);
  assert.equal(M.activeTab().root.id, moved);
  Umi.actions.paneToTabUp();
  assert.deepEqual(Umi.state.layout.tabs, [tab]);
  assert.equal(tab.focused, moved);
  assert.deepEqual(widths(tab.root), [25, 25, 25, 25]);
}

const source = row([1, 2, 3]), destination = row([1, 1]);
Umi.state.layout = { tabs: [source, destination], activeTab: source.id };
Umi.actions.paneToTabDown();
assert.deepEqual(widths(source.root), [40, 60]);
assert.deepEqual(widths(destination.root), [33, 33, 33]);

Umi.state.layout.activeTab = source.id;
Umi.actions.paneToTabUp();
assert.equal(M.activeTab(), Umi.state.layout.tabs[2]);
assert.equal(Umi.state.layout.tabs[1], destination);
