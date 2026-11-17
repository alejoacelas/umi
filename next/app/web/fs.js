// Files and search for the web layer, served natively (Sources/UmiNext/Services.swift).
// Every call returns a promise; failures reject with an Error whose `code` says why:
// notFound, isDir, binary, tooLarge, conflict, badPath, noRipgrep, searchFailed, io.
// A relative path resolves against root(): the focused pane's project folder (its git main
// folder, else its folder). `~/` means the home folder.
//
//   Umi.fs.root()                                   → '/abs/project'
//   Umi.fs.resolve(path, base = root())             → absolute path
//   Umi.fs.read(path)                               → {path, text, version, size, mtime}
//   Umi.fs.write(path, text, {version, createDirs}) → {path, version, size}
//       Atomic. With `version` (from read/write), writes only if the file is still at that version,
//       else rejects with code 'conflict'; `version: null` writes only if the file doesn't exist.
//       Without `version`, overwrites.
//   Umi.fs.list(dir, {hidden, ignored})             → {dir, git, entries: [{name, path, kind: 'file'|'dir',
//       link?, size, mtime, hidden, ignored}]}  folders first; dotfiles only with `hidden`, files git
//       ignores only with `ignored`; `.git` never.
//   Umi.fs.watch(path, onChange)                    → {close(), done}
//       onChange({changes: [{path, kinds: ['created'|'removed'|'modified'|'renamed'|'rescan'], exists}]}),
//       coalesced over 50 ms; a folder is watched recursively. Changes inside .git are left out unless
//       the path is inside .git. Watches end when the page reloads.
//   Umi.fs.files(root = root(), {limit})            → {root, files: ['rel/path', …], source: 'git'|'walk', truncated}
//       What git tracks plus untracked files it doesn't ignore; outside a repository a walk.
//   Umi.fs.fuzzy(query, files, limit = 50)          → [{path, score, hits: [index, …]}] best first (pure JS)
//   Umi.fs.search(query, {root, regex, caseSensitive, wholeWord, glob: ['*.md'], hidden, ignored,
//       maxResults = 5000}, onMatches)              → {cancel(), done}
//       ripgrep. onMatches([{path (relative to root), line, text, ranges: [[start, end], …]}]) gets
//       batches as they arrive (ranges are JS string indexes into text). `done` resolves with
//       {count, files, truncated, cancelled, ms}. `pcre2: true` with `regex`: Perl-style (lookarounds).
//   Umi.fs.trash(path)                              → {path, trashed}   moved to the Trash
//   Umi.fs.rename(path, to)                         → {path}            refused ('exists') if `to` is taken
//   Umi.fs.reveal(path)                             shows it in Finder
//   Umi.fs.openDefault(path)                        opens it with its default app
// Other native services: bridge ops 'clipboard' {text?}, 'sendText' {session, text} (types into a
// daemon session) and 'menu' {items: [{title, enabled?} | {separator: true}], x, y} → {index|null}.
'use strict';
window.Umi = window.Umi || {};

Umi.fs = (() => {
  const req = (op, args, onEvent) => Umi.bridge.request(op, args, onEvent);

  function root() {
    const M = Umi.model, S = Umi.state;
    if (!S.layout) return S.home || '/';
    const tab = M.activeTab();
    return (tab && M.projectOf(tab.focused)) || S.home || '/';
  }

  function resolve(path, base = root()) {
    if (!path) return base;
    if (path === '~' || path.startsWith('~/')) path = (Umi.state.home || '') + path.slice(1);
    else if (!path.startsWith('/')) path = base.replace(/\/$/, '') + '/' + path;
    // Normalise . and .. segments.
    const out = [];
    for (const seg of path.split('/')) {
      if (seg === '' || seg === '.') continue;
      if (seg === '..') out.pop(); else out.push(seg);
    }
    return '/' + out.join('/');
  }

  const read = (path) => req('readFile', { path: resolve(path) });

  function write(path, text, opts = {}) {
    const args = { path: resolve(path), text };
    if ('version' in opts) args.version = opts.version;
    if (opts.createDirs) args.createDirs = true;
    return req('writeFile', args);
  }

  const list = (dir, { hidden = false, ignored = false } = {}) => req('listDir', { path: resolve(dir), hidden, ignored });

  function watch(path, onChange) {
    const done = req('watch', { path: resolve(path) }, onChange);
    return { done, close: () => req('cancel', { target: done.id }) };
  }

  const files = (r = root(), { limit } = {}) => req('listFiles', { root: resolve(r), ...(limit ? { limit } : {}) });

  function search(query, opts = {}, onMatches = () => {}) {
    const { root: r = root(), ...rest } = opts;
    const done = req('search', { query, root: resolve(r), ...rest }, (d) => onMatches(d.matches));
    return { done, cancel: () => req('cancel', { target: done.id }) };
  }

  // Subsequence match of `query` in `path`, scored: consecutive letters, letters at word starts
  // (after / . _ - or a case change) and matches in the file name count more; shorter paths win ties.
  function scoreOne(q, path) {
    const lower = path.toLowerCase();
    const nameStart = path.lastIndexOf('/') + 1;
    let score = 0, last = -2, pi = 0;
    const hits = [];
    for (let qi = 0; qi < q.length; qi++) {
      const c = q[qi];
      if (c === ' ') continue;
      const at = lower.indexOf(c, pi);
      if (at < 0) return null;
      const prev = path[at - 1];
      let s = 1;
      if (at === last + 1) s += 4;
      if (at === 0 || '/._- '.includes(prev) || (prev && prev === prev.toLowerCase() && path[at] !== path[at].toLowerCase())) s += 3;
      if (at >= nameStart) s += 2;
      score += s;
      hits.push(at);
      last = at;
      pi = at + 1;
    }
    if (lower.slice(nameStart).startsWith(q)) score += 6;
    return { path, score: score - path.length * 0.01, hits };
  }

  function fuzzy(query, list, limit = 50) {
    const q = query.trim().toLowerCase();
    if (!q) return list.slice(0, limit).map((path) => ({ path, score: 0, hits: [] }));
    const out = [];
    for (const p of list) { const r = scoreOne(q, p); if (r) out.push(r); }
    out.sort((a, b) => b.score - a.score);
    return out.slice(0, limit);
  }

  const trash = (path) => req('trash', { path: resolve(path) });
  const rename = (path, to) => req('rename', { path: resolve(path), to: resolve(to) });
  const reveal = (path) => req('reveal', { path: resolve(path) });
  const openDefault = (path) => req('openDefault', { path: resolve(path) });

  return { root, resolve, read, write, list, watch, files, fuzzy, search, trash, rename, reveal, openDefault };
})();
