// The terminal's right-click menu (SPEC L-31), as Umi's (UmiPaneMenu): Warp's items in Warp's
// order, each with its key, then Ghostty's. Native sends `termMenu {pane, x, y, selected,
// selectedBefore, alternate, clipboard, readonly}` for a right-click the program didn't take
// (no mouse reporting); the menu is native (bridge `menu`) and acts on the pane right-clicked,
// focused or not.
//
//   Copy (with text selected) | Paste (greyed with nothing to paste), Clear (neither with text
//   selected before the click or a full-screen program showing) | Split Pane Right, Split Pane
//   Down, and in a split Maximize Pane (Minimize Pane) and Close Pane | Reset Terminal, Terminal
//   Read-only | Change Tab Title..., Change Terminal Title...
//
// Departures (PARITY.md): no Split Pane Left / Up (Next splits right and down), no Toggle Terminal
// Inspector (Next has no inspector); Change Terminal Title... renames the session, which is what
// a pane's name is in Next.
'use strict';
Umi.views = Umi.views || {};

Umi.views.termMenu = (() => {
  const S = Umi.state, M = Umi.model;

  // The key an item shows: the page's table for its actions, the terminal's Ghostty binding with ⌘
  // for its own (Copy, Paste, Clear; none when the config unbinds them), Ghostty's default until
  // the bindings are read.
  const tableKey = (id) => Umi.shortcuts.table.find((e) => e.id === id)?.keys || undefined;
  function ghosttyKey(action, fallback) {
    const all = Umi.ghostty?.bindings;
    if (!all) return fallback;
    const b = all.find((x) => (x.action === action || x.action.startsWith(action + ':')) && /(^|\+)cmd\+/.test(x.keys || ''));
    return b ? b.keys : undefined;
  }

  // The items for the message, without acting: [{title, key?, enabled?, checked?, fn} | {separator}].
  function items(msg) {
    const out = [];
    const add = (title, fn, extra = {}) => out.push({ title, fn, ...extra });
    const sep = () => { if (out.length && !out[out.length - 1].separator) out.push({ separator: true }); };
    const pane = msg.pane;
    const term = (action) => () => Umi.bridge.request('termAction', { pane, action });
    // An action of the page's on this pane: focus it first, as Umi's items act on the pane clicked.
    const onPane = (fn) => () => Umi.app.update(() => { M.focusPane(pane); fn(); });
    const found = M.findPane(pane);
    const split = !!found && M.paneIds(found.tab.root).length > 1;
    const zoomed = !!found && found.tab.zoomed === pane;
    if (msg.selected) { add('Copy', term('copy'), { key: ghosttyKey('copy_to_clipboard', 'cmd+c') }); sep(); }
    if (!(msg.selectedBefore ?? msg.selected) && !msg.alternate) {
      add('Paste', term('paste'), { key: ghosttyKey('paste_from_clipboard', 'cmd+v'), enabled: !!msg.clipboard });
      sep();
      add('Clear', term('clear'), { key: ghosttyKey('clear_screen', 'cmd+k') });
      sep();
    }
    add('Split Pane Right', onPane(() => Umi.actions.splitRight()), { key: tableKey('splitRight') });
    add('Split Pane Down', onPane(() => Umi.actions.splitDown()), { key: tableKey('splitDown') });
    if (split) {
      add(zoomed ? 'Minimize Pane' : 'Maximize Pane', onPane(() => Umi.actions.toggleZoom()), { key: tableKey('toggleZoom') });
      add('Close Pane', onPane(() => Umi.actions.closePane()), { key: tableKey('closePane') });
    }
    sep();
    add('Reset Terminal', term('reset'));
    add('Terminal Read-only', term('readonly'), { checked: !!msg.readonly });
    sep();
    add('Change Tab Title...', onPane(() => Umi.actions.renameTab()), { key: tableKey('renameTab') });
    add('Change Terminal Title...', onPane(() => Umi.actions.renameSession()), { key: tableKey('renameSession') });
    return out;
  }

  async function show(msg) {
    const list = items(msg);
    const r = await Umi.bridge.request('menu', {
      items: list.map(({ title, enabled, checked, key, separator }) => (separator ? { separator } : { title, enabled, checked, key })),
      x: msg.x, y: msg.y,
    });
    if (r && r.index != null) list[r.index].fn();
  }

  return { items, show };
})();

Umi.bridge.on('termMenu', (msg) => { if (Umi.state.layout) Umi.views.termMenu.show(msg); });
