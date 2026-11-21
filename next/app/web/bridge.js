// The link to the native shell (Sources/UmiNext/MainWindow.swift).
//   to native:   hello · layout {layout, closed} · rects {rects, passThrough, holes, chrome, cover,
//                tint, fade, viewport, focus?} · focusWeb · log {message} · shortcuts {table} · reload
//                · exitSession {session} · pastSessions {project} · badge {count}
//                · docket {session, name} · undocket {session}
//                · request {id, op, args} (Umi.bridge.request; Sources/UmiNext/Services.swift, and
//                  MainWindow.swift for termSearch, termSearchNav, termSearchEnd, termAction)
//                · cliReply {id, ok, result|error} (web/cli.js; Sources/UmiNext/ControlServer.swift)
//                · error {message}: sent by the script native injects, for uncaught errors and
//                  unhandled rejections (native shows them in its banner)
//   from native: state · sessions {list} · pastSessions {project, list} · pane {id, info}
//                · focused {pane} · action {name, ...} · paneExited {pane} · shortcut {id}
//                · search {pane, total?, selected?} · searchEnded {pane} · termMenu {pane, x, y, ...}
//                · reply {id, ok, result|error} · event {id, data} · cli {id, req} · cliCancel {id}
'use strict';
window.Umi = window.Umi || {};

Umi.bridge = {
  post(msg) { window.webkit.messageHandlers.umi.postMessage(msg); },
  handlers: {},
  on(type, fn) { this.handlers[type] = fn; },

  // Asks native for a service: resolves with its result, or rejects with an Error carrying `code`
  // (e.g. 'notFound', 'conflict'). `onEvent(data)` gets the pushes a long request (watch, search)
  // sends before its reply. The promise has `.id`, for op 'cancel' {target: id}.
  request(op, args = {}, onEvent = null) {
    const id = 'r' + (++this._seq);
    const promise = new Promise((resolve, reject) => { this._pending.set(id, { resolve, reject, onEvent }); });
    promise.id = id;
    this.post({ type: 'request', id, op, args });
    return promise;
  },
  _seq: 0,
  _pending: new Map(),
};

Umi.bridge.on('reply', (msg) => {
  const p = Umi.bridge._pending.get(msg.id);
  if (!p) return;
  Umi.bridge._pending.delete(msg.id);
  if (msg.ok) p.resolve(msg.result);
  else p.reject(Object.assign(new Error(msg.error?.message || 'failed'), { code: msg.error?.code || 'error' }));
});
Umi.bridge.on('event', (msg) => {
  const p = Umi.bridge._pending.get(msg.id);
  if (p && p.onEvent) p.onEvent(msg.data);
});

window.umiNative = {
  receive(msg) {
    const fn = Umi.bridge.handlers[msg.type];
    if (fn) fn(msg);
    else Umi.bridge.post({ type: 'log', message: 'no handler for ' + msg.type });
  },
};
