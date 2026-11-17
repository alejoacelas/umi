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
//   Umi.fs.gitRoot(path)                            → {root}            the repository's top folder (a worktree's own), or null
//   Umi.fs.trash(path)                              → {path, trashed}   moved to the Trash
//   Umi.fs.rename(path, to)                         → {path}            refused ('exists') if `to` is taken
//   Umi.fs.reveal(path)                             shows it in Finder
//   Umi.fs.openDefault(path)                        opens it with its default app
//   Umi.fs.readData(path)                           → {path, mime, base64, size}  up to 16 MB (preview images)
//   Umi.fs.openURL(url)                             opens an http(s)/mailto link in the default app
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

  // Umi's palette scorer (UmiFuzzy.score): a greedy left-to-right subsequence match; consecutive
  // letters score more the longer the run, a gap costs up to 3, the first letter or one after a
  // separator (/ . _ - space) or at a case change scores more; shorter texts win ties.
  const SEP = new Set(['/', '.', '_', '-', ' ']);
  function scoreIn(q, text, offset, hits) {
    const lower = text.toLowerCase();
    let score = 0, qi = 0, prev = -2, streak = 0;
    for (let ti = 0; ti < text.length && qi < q.length; ti++) {
      if (lower[ti] !== q[qi]) continue;
      let pts = 1;
      if (ti === prev + 1) { streak++; pts += 4 + streak; } else { streak = 0; if (prev >= 0) pts -= Math.min(ti - prev - 1, 3); }
      if (ti === 0) pts += 8;
      else {
        const b = text[ti - 1], c = text[ti];
        if (SEP.has(b) || (c !== c.toLowerCase() && b === b.toLowerCase() && b !== b.toUpperCase())) pts += 6;
      }
      score += pts;
      hits.push(ti + offset);
      prev = ti;
      qi++;
    }
    if (qi < q.length) return null;
    return score * 4 - Math.floor(Math.min(text.length, 120) / 8);
  }

  // A match within the file name counts double (as Umi's quick open); its letters are the hits.
  function scoreOne(q, path) {
    const nameStart = path.lastIndexOf('/') + 1;
    const hits = [];
    const full = scoreIn(q, path, 0, hits);
    if (full == null) return null;
    const nameHits = [];
    const name = scoreIn(q, path.slice(nameStart), nameStart, nameHits);
    if (name != null && name * 2 >= full) return { path, score: name * 2, hits: nameHits };
    return { path, score: full, hits };
  }

  function fuzzy(query, list, limit = 50) {
    const q = query.trim().toLowerCase().replace(/ /g, '');
    if (!q) return list.slice(0, limit).map((path) => ({ path, score: 0, hits: [] }));
    const out = [];
    for (const p of list) { const r = scoreOne(q, p); if (r) out.push(r); }
    out.sort((a, b) => b.score - a.score || a.path.length - b.path.length);
    return out.slice(0, limit);
  }

  const gitRoot = (path) => req('gitRoot', { path: resolve(path) });
  const trash = (path) => req('trash', { path: resolve(path) });
  const rename = (path, to) => req('rename', { path: resolve(path), to: resolve(to) });
  const reveal = (path) => req('reveal', { path: resolve(path) });
  const openDefault = (path) => req('openDefault', { path: resolve(path) });
  const readData = (path) => req('readData', { path: resolve(path) });
  const openURL = (url) => req('openURL', { url });

  return { root, resolve, read, write, list, watch, files, fuzzy, search, gitRoot, trash, rename, reveal, openDefault, readData, openURL };
})();
