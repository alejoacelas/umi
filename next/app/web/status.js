// The status line at the end of an agent's reply, read as agent-emacs's
// `agent-session-reply-status` does (next/DESIGN.md, "Detached sessions that finish done stay out
// of the way"): the last line of the reply that starts with `Status:` once list marks (`-`, `*`,
// `+`, `1.`), quote marks and emphasis (`*`, `_`, `` ` ``) are stripped, case ignored.
//
//   parseStatus(text) → { kind, detail, line } | null   (line: the reply's line as written)
//     kind: 'done' | 'pending' (done, pending verification: X) | 'waiting' (waiting on you: X)
//           | 'progress' (in progress: X next) | 'other' (a Status: line saying something else)
//     null: no status line.
'use strict';
(function (root) {
  function clean(line) {
    let s = line.trim();
    s = s.replace(/^>\s*/, '');                 // quote
    s = s.replace(/^(?:[-*+•]|\d+[.)])\s+/, '');  // list mark
    s = s.replace(/^[*_`~]+/, '').replace(/[*_`~]+$/, '').trim(); // emphasis around the line
    s = s.replace(/^status\s*[*_`]+\s*:/i, 'status:').replace(/^status:\s*[*_`]+/i, 'status: ');
    return s.replace(/[*_`]+$/, '').trim();
  }

  function parseStatus(text) {
    if (!text) return null;
    const lines = String(text).split(/\r?\n/);
    for (let i = lines.length - 1; i >= 0; i--) {
      const s = clean(lines[i]);
      const m = /^status\s*:\s*(.*)$/i.exec(s);
      if (!m) continue;
      const v = m[1].replace(/[*_`]/g, '').trim();
      const line = lines[i].trim();
      let r;
      if ((r = /^done\s*,\s*pending verification\s*:?\s*(.*)$/i.exec(v))) return { kind: 'pending', detail: r[1].trim(), line };
      if (/^done\.?$/i.test(v)) return { kind: 'done', detail: '', line };
      if ((r = /^waiting on you\s*:?\s*(.*)$/i.exec(v))) return { kind: 'waiting', detail: r[1].trim(), line };
      if ((r = /^in progress\s*:?\s*(.*)$/i.exec(v))) return { kind: 'progress', detail: r[1].trim(), line };
      return { kind: 'other', detail: v, line };
    }
    return null;
  }

  // Whether a finished turn with this reply can stay out of Review: only a readable done.
  const isDone = (st) => !!st && (st.kind === 'done' || st.kind === 'pending');

  const api = { parseStatus, isDone };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else { root.Umi = root.Umi || {}; root.Umi.status = api; }
})(typeof window !== 'undefined' ? window : globalThis);
