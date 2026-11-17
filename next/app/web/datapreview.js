// Previews for data files (SPEC E-1), as Umi's UmiDataPreview.swift: JSON as a tree whose
// objects and arrays fold (keys in file order, <details>, so the preview runs no script), CSV and
// TSV as a table (row numbers, a header that stays in view, numeric columns right-aligned).
//
//   UmiData.handles(path)     → true for .json .csv .tsv
//   UmiData.html(path, text)  → HTML for the preview iframe's #umi-doc
//   UmiData.rows(text, sep)   → [[cell, …], …] (RFC 4180 quoting)
'use strict';

const UmiData = (() => {
  const EXT = new Set(['json', 'csv', 'tsv']);
  const ext = (p) => ((/\.([^./]+)$/.exec(p || '') || [])[1] || '').toLowerCase();
  const esc = (t) => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  const handles = (path) => EXT.has(ext(path));

  function html(path, text) {
    switch (ext(path)) {
      case 'json': return json(text);
      case 'csv': return table(text, ',');
      case 'tsv': return table(text, '\t');
      default: return `<pre>${esc(text)}</pre>`;
    }
  }

  // ---- JSON: a small parser that keeps keys in file order and says where it failed ----
  function parseJSON(s) {
    let i = 0;
    const fail = (m) => { const e = new Error(`${m} on line ${s.slice(0, i).split('\n').length}`); e.json = true; return e; };
    const skip = () => { while (i < s.length && ' \n\r\t'.includes(s[i])) i++; };
    function str() {
      i++;
      let out = '';
      while (i < s.length) {
        const c = s[i++];
        if (c === '"') return out;
        if (c === '\\' && i < s.length) {
          const e = s[i++];
          if (e === 'u') {
            const h = s.slice(i, i + 4);
            if (!/^[0-9a-fA-F]{4}$/.test(h)) throw fail('bad \\u escape');
            out += String.fromCharCode(parseInt(h, 16));
            i += 4;
          } else out += { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f' }[e] ?? e;
        } else out += c;
      }
      throw fail('unterminated string');
    }
    function word(w, v) {
      if (s.slice(i, i + w.length) !== w) throw fail('unexpected word');
      i += w.length;
      return v;
    }
    function value() {
      skip();
      if (i >= s.length) throw fail('unexpected end');
      const c = s[i];
      if (c === '{') {
        i++;
        const members = [];
        skip();
        if (s[i] === '}') { i++; return { t: 'object', members }; }
        for (;;) {
          skip();
          if (s[i] !== '"') throw fail('expected a key');
          const k = str();
          skip();
          if (s[i] !== ':') throw fail("expected ':'");
          i++;
          members.push([k, value()]);
          skip();
          if (i >= s.length) throw fail('unexpected end');
          if (s[i] === ',') { i++; continue; }
          if (s[i] === '}') { i++; return { t: 'object', members }; }
          throw fail("expected ',' or '}'");
        }
      }
      if (c === '[') {
        i++;
        const items = [];
        skip();
        if (s[i] === ']') { i++; return { t: 'array', items }; }
        for (;;) {
          items.push(value());
          skip();
          if (i >= s.length) throw fail('unexpected end');
          if (s[i] === ',') { i++; continue; }
          if (s[i] === ']') { i++; return { t: 'array', items }; }
          throw fail("expected ',' or ']'");
        }
      }
      if (c === '"') return { t: 'string', v: str() };
      if (c === 't') return word('true', { t: 'bool', v: 'true' });
      if (c === 'f') return word('false', { t: 'bool', v: 'false' });
      if (c === 'n') return word('null', { t: 'null' });
      const start = i;
      while (i < s.length && '+-0123456789.eE'.includes(s[i])) i++;
      if (i === start) throw fail('unexpected character');
      return { t: 'number', v: s.slice(start, i) };
    }
    const v = value();
    skip();
    if (i < s.length) throw fail('unexpected text after the value');
    return v;
  }

  function render(v, key, depth) {
    const label = key == null ? '' : `<span class="k">${esc(key)}</span><span class="p">: </span>`;
    switch (v.t) {
      case 'object': return container(label, '{', '}', v.members.length, 'key', v.members.map(([k, x]) => `<li>${render(x, k, depth + 1)}</li>`).join(''), depth);
      case 'array': return container(label, '[', ']', v.items.length, 'item', v.items.map((x, n) => `<li>${render(x, String(n), depth + 1)}</li>`).join(''), depth);
      case 'string': return `${label}<span class="s">"${esc(v.v)}"</span>`;
      case 'number': return `${label}<span class="n">${esc(v.v)}</span>`;
      case 'bool': return `${label}<span class="b">${v.v}</span>`;
      default: return `${label}<span class="z">null</span>`;
    }
  }

  function container(label, open, close, count, noun, inner, depth) {
    if (!count) return `${label}<span class="p">${open}${close}</span>`;
    return `<details${depth < 3 ? ' open' : ''}><summary>${label}<span class="p">${open}</span>`
      + `<span class="c"> ${count} ${noun}${count === 1 ? '' : 's'} </span><span class="p fold">${close}</span></summary>`
      + `<ul>${inner}</ul><span class="p">${close}</span></details>`;
  }

  function json(text) {
    try { return STYLE + `<div class="umi-json">${render(parseJSON(text), null, 0)}</div>`; } catch (e) {
      if (!e.json) throw e;
      return STYLE + `<p class="umi-data-err">Can't show a tree: ${esc(e.message)}. Switch to Raw to fix it.</p>`;
    }
  }

  // ---- CSV / TSV ----
  function rows(text, sep) {
    const out = [];
    let row = [], field = '', quoted = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (quoted) {
        if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else quoted = false; } else field += c;
      } else if (c === '"') quoted = true;
      else if (c === sep) { row.push(field); field = ''; }
      else if (c === '\n') { row.push(field); out.push(row); row = []; field = ''; }
      else if (c !== '\r') field += c;
    }
    if (field || row.length) { row.push(field); out.push(row); }
    return out;
  }

  function table(text, sep) {
    const all = rows(text, sep);
    if (!all.length) return STYLE + '<p class="c">Empty file.</p>';
    const [header, ...body] = all;
    const columns = Math.max(...all.map((r) => r.length));
    const isNum = (x) => x.trim() !== '' && !isNaN(Number(x));
    const numeric = Array.from({ length: columns }, (_, c) => body.every((r) => c >= r.length || r[c] === '' || isNum(r[c])));
    const cells = (r, tag) => Array.from({ length: columns }, (_, c) => `<${tag}${numeric[c] ? ' class="num"' : ''}>${esc(c < r.length ? r[c] : '')}</${tag}>`).join('');
    return STYLE + `<p class="c">${body.length} rows × ${columns} columns</p>`
      + `<table class="umi-grid"><thead><tr><th class="rn"></th>${cells(header, 'th')}</tr></thead><tbody>`
      + body.map((r, n) => `<tr><td class="rn">${n + 1}</td>${cells(r, 'td')}</tr>`).join('')
      + '</tbody></table>';
  }

  const STYLE = `<style>
.umi-json { font: 12.5px/1.7 var(--mono); }
.umi-json ul { list-style: none; margin: 0; padding-left: 1.4em; border-left: 1px solid rgba(128,128,128,0.15); }
.umi-json li { margin: 0; }
.umi-json details > summary { cursor: pointer; list-style: none; }
.umi-json details > summary::-webkit-details-marker { display: none; }
.umi-json details > summary::before { content: "▸"; display: inline-block; width: 1em; margin-left: -1em; opacity: 0.5; }
.umi-json details[open] > summary::before { content: "▾"; }
.umi-json details[open] > summary .c, .umi-json details[open] > summary .fold { display: none; }
.umi-json .k { color: #7aa2f7; } .umi-json .s { color: #9ece6a; } .umi-json .n { color: #e0af68; } .umi-json .b, .umi-json .z { color: #bb9af7; }
.umi-json .p { opacity: 0.6; } #umi-doc .c { opacity: 0.55; font-size: 12px; }
.umi-data-err { color: #f7768e; }
table.umi-grid { font: 12.5px/1.4 var(--mono); border-collapse: collapse; }
table.umi-grid th { position: sticky; top: 0; background: rgba(128,128,128,0.15); backdrop-filter: blur(8px); }
table.umi-grid th, table.umi-grid td { padding: 5px 12px; border: 1px solid rgba(128,128,128,0.15); white-space: nowrap; }
table.umi-grid tbody tr:nth-child(even) { background: rgba(128,128,128,0.05); }
table.umi-grid .num { text-align: right; font-variant-numeric: tabular-nums; }
table.umi-grid .rn { opacity: 0.4; text-align: right; }
</style>`;

  return { handles, html, rows, parseJSON };
})();

if (typeof module !== 'undefined') module.exports = UmiData;
