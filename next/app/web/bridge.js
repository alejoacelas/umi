// The link to the native shell (Sources/UmiNext/MainWindow.swift).
//   to native:   hello · layout {layout, closed} · rects {rects, viewport, focus?} · focus {pane}
//                · focusWeb · error {message} · log {message}
//   from native: state · pane {id, info} · focused {pane} · action {name, ...} · paneExited {pane}
'use strict';
window.Umi = window.Umi || {};

Umi.bridge = {
  post(msg) { window.webkit.messageHandlers.umi.postMessage(msg); },
  handlers: {},
  on(type, fn) { this.handlers[type] = fn; },
};

window.umiNative = {
  receive(msg) {
    const fn = Umi.bridge.handlers[msg.type];
    if (fn) fn(msg);
    else Umi.bridge.post({ type: 'log', message: 'no handler for ' + msg.type });
  },
};
