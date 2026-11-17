// The bottom panel host: where the palette will slide up from the window's bottom edge
// (DESIGN "The palette at the bottom"). It takes height from the pane area, because the native
// terminals sit above the web view and would hide anything drawn over them. While a panel is
// open the web view has the keys (native gets `focusWeb`); closing it gives them back.
'use strict';
Umi.views = Umi.views || {};

Umi.views.panel = (() => {
  const S = Umi.state;
  // name -> (element, panel state) => void
  const renderers = {};

  function render() {
    const el = document.querySelector('#panel');
    const p = S.ui.panel;
    el.textContent = '';
    el.hidden = !p;
    if (!p) return;
    const r = renderers[p.name];
    if (r) r(el, p);
    else el.textContent = p.name;
  }

  return { render, renderers };
})();
