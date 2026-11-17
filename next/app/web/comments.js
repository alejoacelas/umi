// Comments on Markdown documents (SPEC E-11), stored in the document itself in Roughdraft
// Flavored Markdown: CriticMarkup anchors in the text and YAML endmatter at the end of the file for
// who wrote what, when, replies and resolved state. A port of Umi's
// app/macos/UmiCLI/UmiComments.swift, so files written by either read the same; offsets are JS
// string indexes (UTF-16, as NSString's). Pure: no DOM, no Umi, so the CLI can run it in
// JavaScriptCore too (`globalThis.UmiComments`). Checks: next/app/tests/comments.test.js.
//
//     Please revisit {==this sentence==}{>>Needs a source.<<}{#c1}.
//
//     ---
//     comments:
//       c1:
//         by: user
//         at: "2026-11-04T10:31:00.000Z"
//         umi-quote: "this sentence"
//         umi-body: "Needs a source."
//       c2:
//         body: "I can add one from the intro."
//         by: AI
//         at: "2026-11-04T10:35:00.000Z"
//         re: c1
//
//   UmiComments.threads(text)                → [{id, body, by, at, status, resolved_note?, quote, line?,
//                                               detached, anchor_deleted, replies: [{id, body, by, at}]}]
//   UmiComments.add(text, body, {start, end}, author, at?) → {text, id}   (throws Failure)
//   UmiComments.reply(text, id, body, author, at?)         → {text, id}
//   UmiComments.edit(text, id, body)                       → text
//   UmiComments.resolve(text, id, resolved, note?)         → text
//   UmiComments.remove(text, id)                           → text
//   UmiComments.relocate({start, end}, oldText, newText)   → {start, end} | null
//   UmiComments.preview(text, resolvedIds)   → {source, fileOffset(start, end)}: the body as Markdown
//       with review markup turned into HTML (<mark class="umi-c" data-ids>, <span class="umi-pin">,
//       <ins>/<del>), and a map from its offsets back to the file's.
'use strict';
(function (root) {
  const USER = 'user', AGENT = 'AI';

  class Failure extends Error {}

  // ---- Code (where review markup is literal) ----

  const endsLine = (c) => c === 0x0A || c === 0x0D || c === 0x85 || c === 0x2028 || c === 0x2029;

  // The parts of `body` that are code: fenced blocks and inline code spans. [[start, end], …] sorted.
  function codeRanges(body) {
    const u = body, length = u.length, ranges = [];
    let fence = null, proseStart = 0;
    const at = (i) => u.charCodeAt(i);
    function spans(from, to) {
      let i = from;
      while (i < to) {
        if (at(i) !== 0x60) { i++; continue; }
        let n = 0;
        while (i + n < to && at(i + n) === 0x60) n++;
        let j = i + n, closed = null;
        while (j < to) {
          if (at(j) === 0x60) {
            let m = 0;
            while (j + m < to && at(j + m) === 0x60) m++;
            if (m === n) { closed = j + m; break; }
            j += m;
          } else {
            if (at(j) === 0x0A && j + 1 < to && at(j + 1) === 0x0A) break;
            j++;
          }
        }
        if (closed !== null) { ranges.push([i, closed]); i = closed; } else i += n;
      }
    }
    let lineStart = 0;
    for (;;) {
      let lineEnd = lineStart;
      while (lineEnd < length && !endsLine(at(lineEnd))) lineEnd++;
      if (lineEnd < length) lineEnd += at(lineEnd) === 0x0D && lineEnd + 1 < length && at(lineEnd + 1) === 0x0A ? 2 : 1;
      let first = lineStart;
      while (first < lineEnd && at(first) === 0x20) first++;
      if (first - lineStart < 4 && first < lineEnd && (at(first) === 0x60 || at(first) === 0x7E)) {
        const ch = at(first);
        let after = first;
        while (after < lineEnd && at(after) === ch) after++;
        const count = after - first;
        if (count >= 3) {
          if (fence) {
            let blank = true;
            for (let k = after; k < lineEnd; k++) {
              const c = at(k);
              if (!(c === 0x20 || c === 0x0A || c === 0x0D) || (c === 0x0D && k + 1 < lineEnd && at(k + 1) === 0x0A)) { blank = false; break; }
            }
            if (fence.ch === ch && count >= fence.count && blank) {
              ranges.push([fence.start, lineEnd]);
              fence = null;
              proseStart = lineEnd;
            }
          } else {
            spans(proseStart, lineStart);
            fence = { ch, count, start: lineStart };
          }
        }
      }
      if (lineEnd >= length) break;
      lineStart = lineEnd;
    }
    if (fence) ranges.push([fence.start, length]); else spans(proseStart, length);
    return ranges.sort((a, b) => a[0] - b[0]);
  }

  function inCode(offset, code) {
    let lo = 0, hi = code.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (offset < code[mid][0]) hi = mid - 1;
      else if (offset >= code[mid][1]) lo = mid + 1;
      else return true;
    }
    return false;
  }

  // ---- Inline markup ----

  const idChar = /[\p{L}\p{N}\p{M}_-]/u;

  // `{#id}` or `{name="value" …}` right at `at`: {attributes, end} or null.
  function metadata(s, at) {
    if (!(at + 2 < s.length) || s[at] !== '{') return null;
    if (s[at + 1] === '#') {
      let i = at + 2;
      while (i < s.length && idChar.test(s[i])) i++;
      if (!(i > at + 2 && i < s.length && s[i] === '}')) return null;
      return { attributes: { id: s.slice(at + 2, i) }, end: i + 1 };
    }
    let i = at + 1;
    const attributes = {};
    const skip = () => { while (i < s.length && s[i] === ' ') i++; };
    skip();
    while (i < s.length && s[i] !== '}') {
      const nameStart = i;
      while (i < s.length && idChar.test(s[i])) i++;
      if (!(i > nameStart && i + 1 < s.length && s[i] === '=' && s[i + 1] === '"')) return null;
      const name = s.slice(nameStart, i);
      i += 2;
      let value = '', closed = false;
      while (i < s.length) {
        const c = s[i];
        if (c === '\\' && i + 1 < s.length) { value += s[i + 1]; i += 2; continue; }
        if (c === '"') { closed = true; i++; break; }
        if (c === '\n') return null;
        value += c;
        i++;
      }
      if (!closed) return null;
      attributes[name] = value;
      skip();
    }
    if (!(i < s.length) || !Object.keys(attributes).length) return null;
    return { attributes, end: i + 1 };
  }

  // Where `close` next occurs at or after `from`, within the paragraph (no blank line between).
  function find(close, s, from) {
    const blank = s.indexOf('\n\n', from);
    const end = blank < 0 ? s.length : blank;
    const r = s.indexOf(close, from);
    return r >= 0 && r + close.length <= end ? r : null;
  }

  // `{>>body<<}` plus its metadata at `at`: {id, body, start, end, attributes}.
  function commentToken(s, at) {
    if (s.substr(at, 3) !== '{>>') return null;
    const close = find('<<}', s, at + 3);
    if (close === null) return null;
    const body = s.slice(at + 3, close);
    let end = close + 3, attributes = {};
    const meta = metadata(s, end);
    if (meta) { attributes = meta.attributes; end = meta.end; }
    return { id: attributes.id ?? null, body, start: at, end, attributes };
  }

  // Anchors {start, end, textStart, textEnd, highlighted, comments} and code ranges of a body.
  function scan(s) {
    const code = codeRanges(s), anchors = [];
    const following = (start) => {
      const list = [];
      let at = start, t;
      while ((t = commentToken(s, at))) { list.push(t); at = t.end; }
      return { list, end: at };
    };
    let i = 0;
    while (i < s.length) {
      if (s[i] !== '{' || !(i + 2 < s.length) || inCode(i, code)) { i++; continue; }
      const opener = s.substr(i, 3);
      if (opener === '{==') {
        const close = find('==}', s, i + 3);
        if (close === null) { i += 3; continue; }
        let after = close + 3;
        const meta = metadata(s, after);
        if (meta) after = meta.end;
        const f = following(after);
        if (f.list.length) anchors.push({ start: i, end: f.end, textStart: i + 3, textEnd: close, highlighted: true, comments: f.list });
        i = f.end;
      } else if (opener === '{>>') {
        const f = following(i);
        if (!f.list.length) { i += 3; continue; }
        anchors.push({ start: i, end: f.end, textStart: i, textEnd: i, highlighted: false, comments: f.list });
        i = f.end;
      } else if (opener === '{++' || opener === '{--' || opener === '{~~') {
        const closer = opener === '{++' ? '++}' : opener === '{--' ? '--}' : '~~}';
        const close = find(closer, s, i + 3);
        if (close === null) { i += 3; continue; }
        let after = close + 3;
        const meta = metadata(s, after);
        if (meta) after = meta.end;
        const f = following(after);
        if (f.list.length) anchors.push({ start: i, end: f.end, textStart: i, textEnd: close + 3, highlighted: true, comments: f.list });
        i = f.end;
      } else i++;
    }
    return { anchors, code };
  }

  const tokenId = (c) => c.id ?? '@' + c.start;

  // ---- Endmatter ----

  const isBlank = (line) => line.trim() === '';
  const indentation = (line) => line.length - line.replace(/^ +/, '').length;

  class Endmatter {
    constructor() { this.order = []; this.comments = {}; this.keyOrder = {}; this.otherSections = []; }
    get isEmpty() { return !this.order.length && !this.otherSections.length; }

    set(id, fields) {
      if (!this.comments[id]) this.order.push(id);
      this.comments[id] = { ...fields };
      const preferred = ['body', 'by', 'at', 're', 'status', 'resolved', 'umi-quote', 'umi-body'];
      this.keyOrder[id] = [...preferred.filter((k) => fields[k] != null), ...Object.keys(fields).filter((k) => !preferred.includes(k)).sort()];
    }

    update(id, fields) {
      const meta = { ...(this.comments[id] || {}) };
      const keys = [...(this.keyOrder[id] || [])];
      if (!this.comments[id]) this.order.push(id);
      for (const key of Object.keys(fields).sort()) {
        const value = fields[key];
        if (value != null) {
          if (meta[key] == null) keys.push(key);
          meta[key] = value;
        } else {
          delete meta[key];
          const at = keys.indexOf(key);
          if (at >= 0) keys.splice(at, 1);
        }
      }
      this.comments[id] = meta;
      this.keyOrder[id] = keys;
    }

    remove(id) {
      delete this.comments[id];
      delete this.keyOrder[id];
      this.order = this.order.filter((x) => x !== id);
    }

    // The body's end and the endmatter: the last `---` line after a blank line, followed only by
    // YAML whose top-level keys include `comments` or `suggestions`.
    static split(s) {
      const none = { bodyEnd: s.length, endmatter: new Endmatter() };
      let marker = s.lastIndexOf('\n\n---\n'), markerLength = 6;
      if (marker < 0) { marker = s.lastIndexOf('\n\r\n---\r\n'); markerLength = 8; }
      let yamlStart, bodyEnd;
      if (marker >= 0) { yamlStart = marker + markerLength; bodyEnd = marker + 1; }
      else if (s.startsWith('---\n') || s.startsWith('---\r\n')) { yamlStart = s.startsWith('---\n') ? 4 : 5; bodyEnd = 0; }
      else return none;
      const parsed = Endmatter.parse(s.slice(yamlStart));
      return parsed ? { bodyEnd, endmatter: parsed } : none;
    }

    static parse(yaml) {
      const result = new Endmatter();
      const lines = yaml.split('\n').map((l) => (l.endsWith('\r') ? l.slice(0, -1) : l));
      let index = 0, sawKnown = false;
      while (index < lines.length) {
        const line = lines[index];
        if (isBlank(line)) { index++; continue; }
        if (indentation(line) !== 0 || !line.includes(':')) return null;
        const key = line.slice(0, line.indexOf(':'));
        if (!key || !/^[\p{L}\p{N}_-]+$/u.test(key)) return null;
        let end = index + 1;
        while (end < lines.length && (lines[end] === '' || indentation(lines[end]) > 0)) end++;
        const section = lines.slice(index, end);
        if (key === 'comments') {
          sawKnown = true;
          if (!parseComments(section.slice(1), result)) return null;
        } else {
          if (key === 'suggestions') sawKnown = true;
          const kept = [...section];
          while (kept.length && isBlank(kept[kept.length - 1])) kept.pop();
          result.otherSections.push(kept.join('\n'));
        }
        index = end;
      }
      return sawKnown ? result : null;
    }

    render() {
      const sections = [];
      if (this.order.length) {
        const lines = ['comments:'];
        for (const id of this.order) {
          const meta = this.comments[id];
          if (!meta) continue;
          lines.push(`  ${quote(id)}:`);
          const ko = this.keyOrder[id] || [];
          const keys = [...ko.filter((k) => meta[k] != null), ...Object.keys(meta).filter((k) => !ko.includes(k)).sort()];
          for (const key of keys) lines.push(`    ${key}: ${quote(meta[key])}`);
        }
        sections.push(lines.join('\n'));
      }
      sections.push(...this.otherSections);
      return sections.join('\n') + '\n';
    }
  }

  function closesDoubleQuote(value) {
    if (!(value.length >= 2 && value.startsWith('"') && value.endsWith('"'))) return false;
    let backslashes = 0, i = value.length - 2;
    while (i > 0 && value[i] === '\\') { backslashes++; i--; }
    return backslashes % 2 === 0;
  }

  function parseComments(lines, result) {
    let index = 0, current = null;
    while (index < lines.length) {
      const line = lines[index];
      if (isBlank(line)) { index++; continue; }
      const indent = indentation(line);
      const content = line.slice(indent);
      const colon = content.indexOf(':');
      if (colon < 0) return false;
      const key = content.slice(0, colon);
      let value = content.slice(colon + 1).trim();
      if (current === null || indent <= 2) {
        if (value !== '' || !key) return false;
        current = unquote(key);
        if (!result.comments[current]) { result.order.push(current); result.comments[current] = {}; }
        index++;
        continue;
      }
      index++;
      if (['|', '|-', '>', '>-', '|+'].includes(value)) {
        const block = [];
        let blockIndent = null;
        while (index < lines.length) {
          const next = lines[index];
          if (isBlank(next)) { block.push(''); index++; continue; }
          const ni = indentation(next);
          if (!(ni > indent)) break;
          if (blockIndent === null) blockIndent = ni;
          block.push(next.slice(Math.min(ni, blockIndent)));
          index++;
        }
        while (block.length && block[block.length - 1] === '') block.pop();
        value = value.startsWith('>') ? block.join(' ') : block.join('\n');
      } else {
        if (value.startsWith('"') && !closesDoubleQuote(value)) {
          while (index < lines.length && !closesDoubleQuote(value)) { value += ' ' + lines[index].trim(); index++; }
        }
        value = unquote(value);
      }
      const meta = result.comments[current];
      if (meta[key] == null) (result.keyOrder[current] = result.keyOrder[current] || []).push(key);
      meta[key] = value;
    }
    return true;
  }

  function unquote(value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      const inner = value.slice(1, -1);
      let out = '';
      for (let i = 0; i < inner.length; i++) {
        const c = inner[i];
        if (c !== '\\') { out += c; continue; }
        const e = inner[++i];
        if (e === undefined) break;
        if (e === 'n') out += '\n';
        else if (e === 't') out += '\t';
        else if (e === 'r') out += '\r';
        else if (e === '0') out += '\0';
        else if (e === 'u') {
          const hex = inner.slice(i + 1, i + 5);
          i += 4;
          const code = parseInt(hex, 16);
          if (!Number.isNaN(code)) out += String.fromCodePoint(code);
        } else out += e; // " \ / and anything else
      }
      return out;
    }
    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1).replace(/''/g, "'");
    return value;
  }

  // A value as YAML: plain when that's unambiguous, else double-quoted.
  function quote(value) {
    const plain = /^[A-Za-z0-9][A-Za-z0-9 _./+-]*$/.test(value) && !value.endsWith(' ')
      && !['true', 'false', 'yes', 'no', 'null', 'on', 'off', '~'].includes(value.toLowerCase())
      && !/^[+-]?(\d+\.?\d*([eE][+-]?\d+)?|\.\d+([eE][+-]?\d+)?|inf(inity)?|nan)$/i.test(value);
    if (plain) return value;
    let out = '"';
    for (const ch of value) {
      if (ch === '"') out += '\\"';
      else if (ch === '\\') out += '\\\\';
      else if (ch === '\n') out += '\\n';
      else if (ch === '\t') out += '\\t';
      else if (ch === '\r') out += '\\r';
      else if (ch.codePointAt(0) < 0x20) out += '\\u' + ch.codePointAt(0).toString(16).padStart(4, '0');
      else out += ch;
    }
    return out + '"';
  }

  // ---- Document ----

  class Document {
    constructor(text) {
      this.text = text;
      const split = Endmatter.split(text);
      this.bodyEnd = split.bodyEnd;
      this.endmatter = split.endmatter;
      const sc = scan(text.slice(0, this.bodyEnd));
      this.anchors = sc.anchors;
      this.code = sc.code;
    }
    get body() { return this.text.slice(0, this.bodyEnd); }

    // Every thread, in document order, then the detached ones.
    get threads() {
      const s = this.text, em = this.endmatter, result = [], seen = new Set();
      let line = 1, counted = 0;
      for (const a of this.anchors) {
        const q = a.highlighted ? s.slice(a.textStart, a.textEnd) : '';
        for (; counted < a.start; counted++) if (s.charCodeAt(counted) === 0x0A) line++;
        for (const c of a.comments) {
          const id = tokenId(c);
          seen.add(id);
          const meta = em.comments[id] || {};
          result.push({
            id, body: c.body, by: meta.by ?? c.attributes.by ?? '', at: meta.at ?? c.attributes.at ?? '',
            resolved: (meta.status ?? c.attributes.status) === 'resolved', resolvedNote: meta.resolved ?? c.attributes.resolved ?? null,
            quote: q, line, detached: false, anchorDeleted: a.highlighted && a.textEnd === a.textStart, replies: [],
          });
        }
      }
      for (const id of em.order) {
        if (seen.has(id)) continue;
        const meta = em.comments[id];
        if (!meta || meta.re != null) continue;
        result.push({ id, body: meta['umi-body'] ?? meta.body ?? '', by: meta.by ?? '', at: meta.at ?? '',
          resolved: meta.status === 'resolved', resolvedNote: meta.resolved ?? null,
          quote: meta['umi-quote'] ?? '', line: null, detached: true, anchorDeleted: false, replies: [] });
        seen.add(id);
      }
      const ids = new Set(result.map((t) => t.id));
      const rootOf = (id, depth = 0) => {
        if (ids.has(id)) return id;
        const parent = em.comments[id]?.re;
        if (depth >= 32 || parent == null || parent === id) return null;
        return rootOf(parent, depth + 1);
      };
      for (const id of em.order) {
        const meta = em.comments[id];
        if (!meta || meta.re == null || ids.has(id)) continue;
        const reply = { id, body: meta.body ?? '', by: meta.by ?? '', at: meta.at ?? '' };
        const r = meta.re !== id ? rootOf(meta.re) : null;
        const index = r === null ? -1 : result.findIndex((t) => t.id === r);
        if (index >= 0) result[index].replies.push(reply);
        else result.push({ id, body: reply.body, by: reply.by, at: reply.at, resolved: meta.status === 'resolved',
          resolvedNote: meta.resolved ?? null, quote: '', line: null, detached: true, anchorDeleted: false, replies: [] });
      }
      return result;
    }

    thread(id) { return this.threads.find((t) => t.id === id || t.replies.some((r) => r.id === id)) || null; }

    inline(id) {
      for (let a = 0; a < this.anchors.length; a++) {
        const c = this.anchors[a].comments.findIndex((x) => tokenId(x) === id);
        if (c >= 0) return { a, c };
      }
      return null;
    }

    get nextID() {
      const used = new Set(this.endmatter.order);
      for (const a of this.anchors) for (const c of a.comments) if (c.id) used.add(c.id);
      let highest = 0;
      for (const id of used) if (/^c\d+$/.test(id)) highest = Math.max(highest, parseInt(id.slice(1), 10));
      let n = highest + 1;
      while (used.has('c' + n)) n++;
      return 'c' + n;
    }

    render() {
      let body = this.body;
      if (this.endmatter.isEmpty) return body;
      const newline = this.text.includes('\r\n') ? '\r\n' : '\n';
      if (body && !body.endsWith('\n')) body += newline;
      const separator = body ? newline : '';
      let yaml = this.endmatter.render();
      if (newline === '\r\n') yaml = yaml.replace(/\n/g, '\r\n');
      return body + separator + '---' + newline + yaml;
    }
  }

  // ---- Changing a document ----

  const now = () => new Date().toISOString();
  const splice = (s, start, end, insert) => s.slice(0, start) + insert + s.slice(end);

  function inlineBody(text) {
    const flat = text.split(/[\n\r\v\f\x85\u2028\u2029]/).map((l) => l.replace(/^[ \t]+|[ \t]+$/g, '')).filter(Boolean).join(' ');
    if (!flat) throw new Failure('the comment is empty');
    if (flat.includes('<<}')) throw new Failure("a comment can't contain <<}");
    return flat;
  }
  function replyBody(text) {
    const t = text.trim();
    if (!t) throw new Failure('the reply is empty');
    return t;
  }

  // Gives an inline comment written without an id (`@offset`) a real one.
  function ensuringID(id, text) {
    if (!id.startsWith('@')) return { text, id };
    const doc = new Document(text);
    const at = doc.inline(id);
    if (!at) throw new Failure('no comment ' + id);
    const comment = doc.anchors[at.a].comments[at.c];
    const newID = doc.nextID;
    const closeEnd = comment.start + 3 + comment.body.length + 3;
    const updated = new Document(splice(text, closeEnd, comment.end, `{#${newID}}`));
    const meta = {};
    for (const key of ['by', 'at', 'status', 'resolved']) if (comment.attributes[key] != null) meta[key] = comment.attributes[key];
    if (meta.by == null) meta.by = 'unknown';
    if (meta.at == null) meta.at = now();
    updated.endmatter.set(newID, meta);
    return { text: updated.render(), id: newID };
  }

  function add(text, body, range, author = USER, time = now()) {
    const inline = inlineBody(body);
    const doc = new Document(text);
    let r = placeable(range, doc);
    const id = doc.nextID;
    const token = `{>>${inline}<<}{#${id}}`;
    let newText;
    const existing = doc.anchors.find((a) => a.highlighted && a.textStart === r.start && a.textEnd === r.end);
    if (existing) {
      newText = splice(text, existing.end, existing.end, token);
      r = { start: existing.textStart, end: existing.textEnd };
    } else {
      const q = text.slice(r.start, r.end);
      newText = splice(text, r.start, r.end, r.end === r.start ? token : `{==${q}==}${token}`);
    }
    const updated = new Document(newText);
    updated.endmatter.set(id, { by: author, at: time, 'umi-quote': text.slice(r.start, r.end), 'umi-body': inline });
    return { text: updated.render(), id };
  }

  const isSpace = (c) => /\s/.test(c);

  // Checks (and adjusts) a range for a new anchor: one block, not in a code block, not across other
  // review markup; whitespace at its ends left out; a partly selected link or code span taken whole.
  function placeable(range, doc) {
    const s = doc.text;
    if (!(range.start >= 0 && range.end <= doc.bodyEnd && range.end >= range.start)) throw new Failure("that text isn't in the document any more");
    let start = range.start, end = range.end;
    while (start < end && isSpace(s[start])) start++;
    while (end > start && isSpace(s[end - 1])) end--;
    for (let i = start; i < end; i++) {
      if (s[i] !== '\n') continue;
      const rest = s.substr(i + 1, 12).replace(/^[ \t]+/, '');
      const startsBlock = rest === '' || rest[0] === '\n' || rest.startsWith('#') || rest.startsWith('>') || rest.startsWith('- ')
        || rest.startsWith('* ') || rest.startsWith('+ ') || rest.startsWith('|') || rest.startsWith('```') || rest.startsWith('~~~')
        || /^\d+[.)] /.test(rest);
      if (startsBlock) {
        end = i;
        while (end > start && isSpace(s[end - 1])) end--;
        break;
      }
    }
    const lineStart = s.lastIndexOf('\n', start - 1) + 1;
    let lineEnd = s.indexOf('\n', start);
    if (lineEnd < 0) lineEnd = s.length;
    if (s.slice(lineStart, lineEnd).trim().startsWith('|')) {
      const pipe = s.slice(start, end).indexOf('|');
      if (pipe >= 0) {
        end = start + pipe;
        while (end > start && isSpace(s[end - 1])) end--;
      }
    }
    if (!(end > start || range.end === range.start)) throw new Failure('select some text to comment on');
    for (const [bs, be] of codeRanges(doc.body)) {
      const touches = (start >= bs && start < be) || (end > start && end - 1 >= bs && end - 1 < be) || (start <= bs && end >= be);
      if (!touches) continue;
      const opening = s.slice(bs, be).replace(/^ +/, '');
      if (opening.startsWith('```') || opening.startsWith('~~~')) throw new Failure("comments on code blocks aren't supported; comment on the text around it");
      start = Math.min(start, bs);
      end = Math.max(end, be);
    }
    const links = /!?\[[^\]\n]*\]\([^)\n]*\)/g;
    const body = doc.body;
    let m;
    while ((m = links.exec(body))) {
      const ls = m.index, le = m.index + m[0].length;
      const startInside = start > ls && start < le, endInside = end > ls && end < le;
      if (startInside !== endInside) { start = Math.min(start, ls); end = Math.max(end, le); }
    }
    const result = { start, end };
    for (const a of doc.anchors) {
      if (a.highlighted && a.textStart === start && a.textEnd === end) return result;
      const overlaps = (Math.min(a.end, end) - Math.max(a.start, start) > 0) || (end === start && start > a.start && start < a.end);
      if (overlaps) throw new Failure('that text overlaps another comment; select text outside it, or reply to that comment');
    }
    const piece = s.slice(start, end);
    for (const marker of ['{==', '==}', '{>>', '<<}', '{++', '++}', '{--', '--}', '{~~', '~~}']) {
      if (piece.includes(marker)) throw new Failure('that text has review markup in it; select text outside it');
    }
    return result;
  }

  function reply(text0, id0, body, author = AGENT, time = now()) {
    const r = replyBody(body);
    const { text, id: rootID } = ensuringID(id0, text0);
    const doc = new Document(text);
    const thread = doc.thread(rootID);
    if (!thread) throw new Failure('no comment ' + id0);
    const newID = doc.nextID;
    doc.endmatter.set(newID, { body: r, by: author, at: time, re: thread.id });
    return { text: doc.render(), id: newID };
  }

  function edit(text0, id0, body) {
    let { text, id } = ensuringID(id0, text0);
    let doc = new Document(text);
    const at = doc.inline(id);
    if (at) {
      const inline = inlineBody(body);
      const c = doc.anchors[at.a].comments[at.c];
      text = splice(text, c.start + 3, c.start + 3 + c.body.length, inline);
      doc = new Document(text);
      if (doc.endmatter.comments[id]) doc.endmatter.update(id, { 'umi-body': inline });
      return doc.render();
    }
    const meta = doc.endmatter.comments[id];
    if (!meta) throw new Failure('no comment ' + id);
    if (meta.re != null) doc.endmatter.update(id, { body: replyBody(body) });
    else doc.endmatter.update(id, { 'umi-body': inlineBody(body) });
    return doc.render();
  }

  function resolve(text0, id0, resolved, note = null) {
    let { text, id } = ensuringID(id0, text0);
    const doc = new Document(text);
    const thread = doc.thread(id);
    if (!thread) throw new Failure('no comment ' + id0);
    id = thread.id;
    if (!doc.endmatter.comments[id]) doc.endmatter.set(id, { by: thread.by || 'unknown', at: thread.at || now() });
    if (resolved) {
      const n = note && note.trim() ? note : null;
      doc.endmatter.update(id, { status: 'resolved', resolved: n });
    } else doc.endmatter.update(id, { status: null, resolved: null });
    return doc.render();
  }

  function remove(text0, id) {
    let doc = new Document(text0);
    if (!doc.thread(id)) throw new Failure('no comment ' + id);
    const gone = new Set([id]);
    let text = text0;
    const at = doc.inline(id);
    if (at) {
      const a = doc.anchors[at.a];
      if (a.comments.length === 1) {
        const keep = a.highlighted ? text.slice(a.textStart, a.textEnd) : '';
        const isSuggestion = a.highlighted && !text.startsWith('{==', a.start);
        text = isSuggestion ? splice(text, a.comments[at.c].start, a.comments[at.c].end, '') : splice(text, a.start, a.end, keep);
      } else text = splice(text, a.comments[at.c].start, a.comments[at.c].end, '');
      doc = new Document(text);
    }
    let changed = true;
    while (changed) {
      changed = false;
      for (const [key, meta] of Object.entries(doc.endmatter.comments)) {
        if (!gone.has(key) && meta.re != null && gone.has(meta.re)) { gone.add(key); changed = true; }
      }
    }
    for (const key of gone) doc.endmatter.remove(key);
    return doc.render();
  }

  const commonPrefix = (a, b) => { let i = 0; while (i < a.length && i < b.length && a[i] === b[i]) i++; return i; };
  const commonSuffix = (a, b) => { let i = 0; while (i < a.length && i < b.length && a[a.length - 1 - i] === b[b.length - 1 - i]) i++; return i; };

  // Moves a range of `old` to the same words in `new`: the occurrence whose surroundings match best.
  function relocate(range, old, neu) {
    if (old === neu) return range;
    if (range.end > old.length) return null;
    const q = old.slice(range.start, range.end);
    const before = old.slice(Math.max(0, range.start - 48), range.start);
    const after = old.slice(range.end, range.end + 48);
    if (!q) {
      const f = neu.indexOf(before + after);
      return f < 0 ? null : { start: f + before.length, end: f + before.length };
    }
    let best = null, bestScore = -1, from = 0;
    while (from < neu.length) {
      const r = neu.indexOf(q, from);
      if (r < 0) break;
      const b = neu.slice(Math.max(0, r - 48), r), a = neu.slice(r + q.length, r + q.length + 48);
      const score = commonSuffix(b, before) + commonPrefix(a, after);
      if (score > bestScore) { best = { start: r, end: r + q.length }; bestScore = score; }
      from = r + 1;
    }
    return best;
  }

  // ---- The preview ----

  const escapeHTML = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  function preview(text, resolvedIds = new Set()) {
    const doc = text instanceof Document ? text : new Document(text);
    const s = doc.text, body = doc.bodyEnd, code = doc.code;
    let out = '';
    const segments = []; // [previewOffset, fileOffset, length]
    const copy = (from, to) => { if (to > from) { segments.push([out.length, from, to - from]); out += s.slice(from, to); } };
    const emit = (html) => { out += html; };
    const attr = (ids) => escapeHTML(ids.join(' '));
    function suggestionOrText(from, to) {
      const t = s.slice(from, to);
      if (t.startsWith('{++') && t.endsWith('++}')) { emit('<ins>'); copy(from + 3, to - 3); emit('</ins>'); }
      else if (t.startsWith('{--') && t.endsWith('--}')) { emit('<del>'); copy(from + 3, to - 3); emit('</del>'); }
      else if (t.startsWith('{~~') && t.endsWith('~~}')) {
        const arrow = s.indexOf('~>', from + 3);
        if (arrow >= 0 && arrow + 2 <= to - 3) { emit('<del>'); copy(from + 3, arrow); emit('</del><ins>'); copy(arrow + 2, to - 3); emit('</ins>'); }
        else copy(from, to);
      } else copy(from, to);
    }
    const marks = [];
    for (const a of doc.anchors) {
      const ids = a.comments.map(tokenId);
      const open = ids.some((i) => !resolvedIds.has(i));
      marks.push({ start: a.start, end: a.end, render: () => {
        if (a.highlighted) {
          emit(`<mark class="${open ? 'umi-c' : 'umi-c umi-resolved'}" data-ids="${attr(ids)}">`);
          suggestionOrText(a.textStart, a.textEnd);
          emit('</mark>');
        } else emit(`<span class="umi-pin${open ? '' : ' umi-resolved'}" data-ids="${attr(ids)}"></span>`);
      } });
    }
    const lone = /\{==(.*?)==\}|\{\+\+(.*?)\+\+\}|\{--(.*?)--\}|\{~~(.*?)~~\}/g;
    const bodyText = s.slice(0, body);
    let next = 0, m;
    while ((m = lone.exec(bodyText))) {
      const rs = m.index, re = m.index + m[0].length;
      while (next < doc.anchors.length && doc.anchors[next].end <= rs) next++;
      const inAnchor = next < doc.anchors.length && Math.min(doc.anchors[next].end, re) - Math.max(doc.anchors[next].start, rs) > 0;
      if (inCode(rs, code) || inAnchor) continue;
      let wholeEnd = re;
      const meta = metadata(s, re);
      if (meta) wholeEnd = meta.end;
      marks.push({ start: rs, end: wholeEnd, render: () => {
        if (s.startsWith('{==', rs)) { emit('<mark class="umi-hl">'); copy(rs + 3, re - 3); emit('</mark>'); }
        else suggestionOrText(rs, re);
      } });
    }
    marks.sort((a, b) => a.start - b.start);
    let cursor = 0;
    for (const mk of marks) {
      if (mk.start < cursor) continue;
      copy(cursor, mk.start);
      mk.render();
      cursor = mk.end;
    }
    copy(cursor, body);
    // The file offset of a stretch of the preview source, when all of it was copied from the file.
    function fileOffset(start, end = start) {
      let lo = 0, hi = segments.length - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1, [p, f, len] = segments[mid];
        if (start < p) hi = mid - 1;
        else if (start >= p + len) lo = mid + 1;
        else return end <= p + len ? f + start - p : null;
      }
      return null;
    }
    return { source: out, segments, fileOffset };
  }

  // Threads as Umi's CLI and preview give them (CLI.md's JSON shape).
  function threads(text) {
    return new Document(text).threads.map((t) => {
      const o = { id: t.id, body: t.body, by: t.by, at: t.at, status: t.resolved ? 'resolved' : 'open', quote: t.quote,
        detached: t.detached, anchor_deleted: t.anchorDeleted, replies: t.replies.map((r) => ({ ...r })) };
      if (t.line != null) o.line = t.line;
      if (t.resolvedNote != null) o.resolved_note = t.resolvedNote;
      return o;
    });
  }

  root.UmiComments = {
    USER, AGENT, Failure, Document, Endmatter, codeRanges, inCode, scan, placeable,
    threads, add, reply, edit, resolve, remove, relocate, preview, escapeHTML, now,
  };
})(typeof window !== 'undefined' ? window : globalThis);
