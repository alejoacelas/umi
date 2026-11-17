// The source editor's git marks (SPEC E-21, Warp's `code/editor/diff.rs`), as Umi's
// UmiGitDiff.marks: how each line differs from the file's last commit.
//
//   UmiGitMarks.marks(base, text) → {line: 'added'|'changed'|'removed'} by 0-based line of `text`:
//       added and changed lines, and 'removed' on the line after lines that were deleted.
'use strict';

const UmiGitMarks = (() => {
  // The old lines removed and the new lines inserted by a shortest edit: common ends trimmed,
  // then an LCS table over the middle (above CAP cells, the whole middle counts as replaced).
  const CAP = 4e6;
  function edit(old, now) {
    const removed = new Set(), inserted = new Set();
    let a = 0;
    while (a < old.length && a < now.length && old[a] === now[a]) a++;
    let b = 0;
    while (b < old.length - a && b < now.length - a && old[old.length - 1 - b] === now[now.length - 1 - b]) b++;
    const n = old.length - a - b, m = now.length - a - b;
    if (n * m > CAP) {
      for (let i = 0; i < n; i++) removed.add(a + i);
      for (let j = 0; j < m; j++) inserted.add(a + j);
      return { removed, inserted };
    }
    // L[i][j]: the longest common run of old[a+i..] and now[a+j..].
    const w = m + 1;
    const L = new Uint32Array((n + 1) * w);
    for (let i = n - 1; i >= 0; i--) {
      for (let j = m - 1; j >= 0; j--) {
        L[i * w + j] = old[a + i] === now[a + j] ? L[(i + 1) * w + j + 1] + 1 : Math.max(L[(i + 1) * w + j], L[i * w + j + 1]);
      }
    }
    let i = 0, j = 0;
    while (i < n && j < m) {
      if (old[a + i] === now[a + j]) { i++; j++; }
      else if (L[(i + 1) * w + j] >= L[i * w + j + 1]) removed.add(a + i++);
      else inserted.add(a + j++);
    }
    while (i < n) removed.add(a + i++);
    while (j < m) inserted.add(a + j++);
    return { removed, inserted };
  }

  function marks(base, text) {
    const old = base.split('\n'), now = text.split('\n');
    const { removed, inserted } = edit(old, now);
    const out = {};
    let i = 0, j = 0;
    while (i < old.length || j < now.length) {
      if (!removed.has(i) && !inserted.has(j)) { i++; j++; continue; }
      const start = j;
      let removedCount = 0;
      while (removed.has(i) || inserted.has(j)) {
        while (removed.has(i)) { i++; removedCount++; }
        while (inserted.has(j)) j++;
      }
      if (j === start) out[Math.min(start, Math.max(now.length - 1, 0))] = 'removed';
      else for (let l = start; l < j; l++) out[l] = removedCount === 0 ? 'added' : 'changed';
    }
    return out;
  }

  return { marks };
})();

if (typeof module !== 'undefined') module.exports = UmiGitMarks;
