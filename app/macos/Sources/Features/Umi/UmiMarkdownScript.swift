import AppKit
import WebKit

/// What the Markdown preview does beyond the page itself (Warp parity, 2026-11-05): code
/// highlighting (highlight.js), each code block's Copy and, for shell blocks, Run in terminal,
/// Mermaid diagrams (mermaid.js) with Raw / Rendered and, when rendered, Open full screen (both
/// beside the language label, Copy and Run at the right, as Warp's footer), and find (⌘F, ⌘G,
/// ⇧⌘G). The scripts run in Umi's content world beside the comment margin's; the document's own
/// scripts still never run (E-7).
///
/// Text Umi adds to the page (button labels) is drawn by CSS, so it is never part of the
/// document's text: comments and find see only the document.
@MainActor
enum UmiMarkdownScript {
    /// The scripts every Markdown preview gets, in order, before the comment margin's.
    static var userScripts: [WKUserScript] {
        [highlightJS, source].map {
            WKUserScript(source: $0, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: UmiCommentsUI.world)
        }
    }

    private static func resource(_ name: String) -> String {
        guard let url = UmiMarkdownStyle.bundled(name, "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            UmiMarkdownStyle.missing("\(name).js")
            return ""
        }
        return text
    }

    static let highlightJS = resource("umi-highlight.min")
    /// Loaded into a page only when it has a diagram (it is 2.5 MB). Ends in a plain value: the
    /// library's own last expression isn't one WebKit can return.
    static let mermaidJS = resource("umi-mermaid.min") + "\n;true;"

    static let source = #"""
    (() => {
      if (window.umiMarkdown || !document.querySelector('meta[name="umi-markdown"]')) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.umi;
      const post = (message) => { if (handler) handler.postMessage(message); };
      const el = (tag, cls, attrs) => { const e = document.createElement(tag); if (cls) e.className = cls; Object.assign(e, attrs || {}); return e; };
      const shells = new Set(['sh', 'shell', 'bash', 'fish', 'zsh', 'warp-runnable-command']);
      const codeText = (block) => { const c = block.querySelector('pre > code'); return c ? c.textContent : ''; };

      // ---- Code blocks: highlighting, Copy, Run in terminal ------------------------------------
      let highlighted = 0;
      for (const block of document.querySelectorAll('.umi-code')) {
        const code = block.querySelector('pre > code');
        const footer = block.querySelector('.umi-code-footer');
        const lang = block.dataset.lang || '';
        if (!code || !footer) continue;
        if (window.hljs && lang && !block.classList.contains('umi-mermaid')) {
          const language = shells.has(lang) ? 'bash' : lang;
          // Highlight inside the run's span, so the text keeps its file offset (comments).
          const target = code.children.length === 1 && code.firstElementChild.matches('span[data-s]') ? code.firstElementChild : code;
          if (hljs.getLanguage(language) && target.children.length === 0) {
            try {
              target.innerHTML = hljs.highlight(target.textContent, { language, ignoreIllegals: true }).value;
              block.classList.add('umi-highlighted');
              highlighted++;
            } catch (e) {}
          }
        }
        if (block.classList.contains('umi-mermaid')) {
          const mode = el('span', 'umi-mode');
          const raw = el('button', 'umi-raw', { type: 'button', title: 'Raw' });
          const rendered = el('button', 'umi-rendered umi-on', { type: 'button', title: 'Rendered' });
          raw.addEventListener('click', () => showDiagram(block, false));
          rendered.addEventListener('click', () => showDiagram(block, true));
          mode.append(raw, rendered);
          const full = el('button', 'umi-full', { type: 'button', title: 'Open full screen' });
          full.addEventListener('click', () => lightbox.open(block));
          footer.append(mode, full);
        }
        const copy = el('button', 'umi-copy', { type: 'button', title: 'Copy' });
        copy.addEventListener('click', () => {
          post({ type: 'copy', text: codeText(block).trim() });
          copy.classList.add('umi-done');
          setTimeout(() => copy.classList.remove('umi-done'), 1200);
        });
        footer.append(copy);
        if (block.classList.contains('umi-shell')) {
          const run = el('button', 'umi-run', { type: 'button', title: 'Run in terminal' });
          run.addEventListener('click', () => post({ type: 'run', text: codeText(block).trim() }));
          footer.append(run);
        }
      }

      // ---- Mermaid -------------------------------------------------------------------------------
      function showDiagram(block, on) {
        if (on && !block.querySelector('.umi-mermaid-view svg')) on = false;
        block.classList.toggle('umi-showing-diagram', on);
        const raw = block.querySelector('.umi-raw'), rendered = block.querySelector('.umi-rendered');
        if (raw) raw.classList.toggle('umi-on', !on);
        if (rendered) rendered.classList.toggle('umi-on', on);
        window.dispatchEvent(new Event('resize'));
      }
      let mermaidRuns = 0;
      async function renderMermaid(light) {
        const blocks = [...document.querySelectorAll('.umi-mermaid')];
        if (!window.mermaid || !blocks.length) return { blocks: blocks.length, rendered: 0, errors: 0 };
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: light ? 'default' : 'dark',
                             fontFamily: "'Umi Roboto', Roboto, sans-serif" });
        let rendered = 0, errors = 0;
        for (const block of blocks) {
          let view = block.querySelector('.umi-mermaid-view');
          if (!view) { view = el('div', 'umi-mermaid-view'); block.insertBefore(view, block.firstChild); }
          const old = block.querySelector('.umi-mermaid-error'); if (old) old.remove();
          try {
            const { svg } = await mermaid.render('umi-mermaid-' + (++mermaidRuns), codeText(block));
            view.innerHTML = svg;
            showDiagram(block, true);
            rendered++;
          } catch (e) {
            errors++;
            const message = el('div', 'umi-mermaid-error');
            message.dataset.error = String((e && e.message) || e);
            block.insertBefore(message, block.querySelector('pre'));
            showDiagram(block, false);
          }
        }
        window.dispatchEvent(new Event('resize'));
        return { blocks: blocks.length, rendered, errors };
      }

      // ---- Lightbox: a diagram larger, over the page; Esc or a click outside closes it -------
      const box = el('div'); box.id = 'umi-lightbox';
      const frame = el('div', 'umi-frame');
      box.append(frame);
      document.documentElement.append(box);
      const lightbox = {
        open(block) {
          // As Warp's: only a diagram on show (Rendered) opens full screen.
          const svg = block.classList.contains('umi-showing-diagram') && block.querySelector('.umi-mermaid-view svg');
          if (!svg) return false;
          frame.replaceChildren(svg.cloneNode(true));
          box.classList.add('umi-open');
          return true;
        },
        close() { box.classList.remove('umi-open'); frame.replaceChildren(); },
        get isOpen() { return box.classList.contains('umi-open'); },
      };
      box.addEventListener('click', (e) => { if (e.target === box) lightbox.close(); });

      // ---- Find ----------------------------------------------------------------------------------
      const bar = el('div'); bar.id = 'umi-find';
      const input = el('input', '', { type: 'text', placeholder: 'Find', spellcheck: false });
      input.setAttribute('aria-label', 'Find in document');
      const count = el('span', 'umi-count');
      const prev = el('button', 'umi-prev', { type: 'button', title: 'Previous match (⇧⌘G)' });
      const next = el('button', 'umi-next', { type: 'button', title: 'Next match (⌘G)' });
      const regex = el('button', 'umi-regex', { type: 'button', title: 'Regex search' });
      const caseButton = el('button', 'umi-case', { type: 'button', title: 'Case-sensitive search' });
      const close = el('button', 'umi-close', { type: 'button', title: 'Close' });
      bar.append(input, count, el('span', 'umi-sep'), prev, next, regex, caseButton, close);
      document.documentElement.append(bar);
      const find = { open: false, regex: false, caseSensitive: false, ranges: [], current: -1, error: false };
      const highlights = (window.CSS && CSS.highlights && window.Highlight) ? CSS.highlights : null;

      function searchable() {
        const out = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: (n) => {
            const p = n.parentElement;
            if (!p || p.closest('#umi-ui, #umi-bar, #umi-toast, .umi-code-footer, .umi-mermaid-view, .umi-mermaid-error, style, script')) return NodeFilter.FILTER_REJECT;
            if (p.closest('.umi-showing-diagram pre')) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_ACCEPT;
          } });
        let n; while ((n = walker.nextNode())) out.push(n);
        return out;
      }
      function search() {
        find.ranges = []; find.current = -1; find.error = false;
        const query = input.value;
        if (find.open && query) {
          let pattern;
          try { pattern = new RegExp(find.regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), find.caseSensitive ? 'g' : 'gi'); }
          catch (e) { find.error = true; }
          if (pattern) {
            const nodes = searchable();
            let text = ''; const starts = [];
            for (const n of nodes) { starts.push(text.length); text += n.data; }
            const at = (offset, end) => {
              let lo = 0, hi = nodes.length - 1;
              while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] < offset || (!end && starts[mid] === offset)) lo = mid; else hi = mid - 1; }
              while (!end && lo < nodes.length - 1 && offset - starts[lo] >= nodes[lo].length) lo++;
              return [nodes[lo], offset - starts[lo]];
            };
            let m;
            while ((m = pattern.exec(text)) && find.ranges.length < 2000) {
              if (m[0].length === 0) { pattern.lastIndex++; continue; }
              const [sn, so] = at(m.index, false), [en, eo] = at(m.index + m[0].length, true);
              const r = document.createRange(); r.setStart(sn, so); r.setEnd(en, eo);
              find.ranges.push(r);
            }
          }
        }
        // The first match from the top of what's on screen.
        if (find.ranges.length) {
          const i = find.ranges.findIndex(r => r.getBoundingClientRect().bottom >= 0);
          find.current = i < 0 ? 0 : i;
        }
        paint(false);
      }
      function paint(scroll) {
        const n = find.ranges.length;
        if (highlights) {
          highlights.delete('umi-find'); highlights.delete('umi-find-current');
          if (find.open && n) {
            highlights.set('umi-find', new Highlight(...find.ranges.filter((_, i) => i !== find.current)));
            highlights.set('umi-find-current', new Highlight(find.ranges[find.current]));
          }
        }
        count.textContent = !input.value ? '' : find.error ? 'Invalid regex' : n === 0 ? 'No matches' : (find.current + 1) + '/' + n;
        prev.disabled = next.disabled = n === 0;
        regex.classList.toggle('umi-on', find.regex);
        caseButton.classList.toggle('umi-on', find.caseSensitive);
        if (scroll && n) {
          const rect = find.ranges[find.current].getBoundingClientRect();
          if (rect.top < 60 || rect.bottom > window.innerHeight - 20) {
            window.scrollTo({ top: window.scrollY + rect.top - window.innerHeight / 3 });
          }
        }
      }
      function openFind(seed) {
        find.open = true;
        bar.classList.add('umi-open');
        if (seed) input.value = seed;
        input.focus(); input.select();
        search(); paint(true);
        return state().find;
      }
      function move(delta) {
        if (!find.open) return openFind();
        const n = find.ranges.length;
        if (n) { find.current = (find.current + delta + n) % n; paint(true); }
        return state().find;
      }
      function closeFind() {
        find.open = false; bar.classList.remove('umi-open');
        find.ranges = []; find.current = -1; paint(false);
        if (document.activeElement === input) input.blur();
        return state().find;
      }
      input.addEventListener('input', () => { search(); paint(true); });
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); move(e.shiftKey ? -1 : 1); }
        else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeFind(); }
      });
      prev.addEventListener('click', () => move(-1));
      next.addEventListener('click', () => move(1));
      regex.addEventListener('click', () => { find.regex = !find.regex; search(); paint(true); input.focus(); });
      caseButton.addEventListener('click', () => { find.caseSensitive = !find.caseSensitive; search(); paint(true); input.focus(); });
      close.addEventListener('click', closeFind);
      document.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape') return;
        if (lightbox.isOpen) { e.preventDefault(); lightbox.close(); }
        else if (find.open) { e.preventDefault(); closeFind(); }
      }, true);

      // ---- For Swift and tests ---------------------------------------------------------------
      function state() {
        const blocks = [...document.querySelectorAll('.umi-code')];
        return {
          code_blocks: blocks.length, highlighted,
          copy_buttons: document.querySelectorAll('.umi-code-footer .umi-copy').length,
          run_buttons: document.querySelectorAll('.umi-code-footer .umi-run').length,
          labels: blocks.map(b => b.querySelector('.umi-code-footer').dataset.label),
          mermaid: { blocks: document.querySelectorAll('.umi-mermaid').length,
                     diagrams: document.querySelectorAll('.umi-mermaid.umi-showing-diagram .umi-mermaid-view svg').length,
                     errors: [...document.querySelectorAll('.umi-mermaid-error')].map(e => e.dataset.error) },
          lightbox: { open: lightbox.isOpen, svg: !!frame.querySelector('svg') },
          find: { open: find.open, query: input.value, count: find.ranges.length, current: find.current,
                  label: count.textContent, focused: document.activeElement === input,
                  highlighted: highlights && highlights.get('umi-find-current') ? highlights.get('umi-find-current').size + (highlights.get('umi-find') ? highlights.get('umi-find').size : 0) : 0,
                  current_text: find.current >= 0 ? find.ranges[find.current].toString() : null,
                  regex: find.regex, case_sensitive: find.caseSensitive },
          links: [...document.querySelectorAll('body a[href]')].map(a => ({ text: a.textContent, href: a.getAttribute('href') })),
          scroll_y: window.scrollY,
        };
      }
      function style(selector, props) {
        const e = document.querySelector(selector);
        if (!e) return null;
        const cs = getComputedStyle(e), out = {};
        for (const p of props) out[p] = cs.getPropertyValue(p);
        const r = e.getBoundingClientRect();
        out.rect = { x: r.x, y: r.y, width: r.width, height: r.height };
        out.window_width = window.innerWidth;
        out.page_width = document.documentElement.clientWidth;
        // Roboto's faces as the page loaded them (four: Latin and Latin Extended, upright and italic).
        const roboto = [...(document.fonts || [])].filter(f => f.family.replace(/['"]/g, '') === 'Umi Roboto');
        out.roboto_faces = roboto.length;
        out.roboto_loaded = roboto.some(f => f.status === 'loaded' && f.style === 'normal');
        return out;
      }
      function click(selector, nth) {
        const all = document.querySelectorAll(selector);
        const e = all[nth || 0];
        if (!e) return false;
        e.click();
        return true;
      }
      function typeInFind(text) {
        if (!find.open) return false;
        input.value += text;
        input.dispatchEvent(new Event('input'));
        return true;
      }
      function key(name, shift) {
        const target = document.activeElement || document.body;
        target.dispatchEvent(new KeyboardEvent('keydown', { key: name, shiftKey: !!shift, bubbles: true, cancelable: true }));
        return true;
      }
      window.umiMarkdown = { renderMermaid, openFind, findNext: () => move(1), findPrevious: () => move(-1), closeFind,
                             lightbox, state, style, click, typeInFind, key,
                             findOpen: () => find.open };
    })();
    """#

    // MARK: Tests (`debug.ui.markdown`)

    /// Read the preview's state or drive it as the user would (its buttons, find), through its
    /// own script.
    /// Where Copy and Copy file path put text: the clipboard, or a private pasteboard once a
    /// test has driven the preview (`debug.ui.markdown`), so tests never touch the user's.
    static var pasteboard = NSPasteboard.general
    private static func useTestPasteboard() -> NSPasteboard {
        if pasteboard == .general {
            pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.umi.debug.markdown.\(UmiPaths.instanceID)"))
            pasteboard.clearContents()
        }
        return pasteboard
    }

    static func debug(_ params: UmiParams) async throws -> [String: Any] {
        guard let path = params.string("path") else { throw UmiError.badRequest("give a path") }
        guard let doc = UmiCommentsUI.documents(at: path).first else { throw UmiError.notFound("\(path) isn't open") }
        let action = params.string("action") ?? "state"
        let board = useTestPasteboard()
        if action == "pasteboard" { return ["text": board.string(forType: .string) ?? ""] }
        guard let preview = doc.commentTarget as? UmiMarkdownPreview.Coordinator,
              let web = preview.web as? UmiPreviewWebView else {
            throw UmiError.badRequest("the document isn't shown in preview")
        }
        switch action {
        case "menu":
            // The preview's right-click menu (Warp's items), built and chosen without a click.
            let menu = web.warpMenu(selection: params.bool("selection") ?? false)
            if let choose = params.string("choose") {
                guard let index = menu.items.firstIndex(where: { $0.title == choose }) else {
                    throw UmiError.notFound("no menu item \(choose)")
                }
                menu.performActionForItem(at: index)
                return ["chose": choose]
            }
            return ["items": menu.items.map { $0.isSeparatorItem ? "-" : $0.title }]
        case "perform":
            // What a menu item with no target does (Edit ▸ Find's items, ⌘E's): its action goes up
            // the responder chain from the focused view, here the preview or the given pane's.
            guard let name = params.string("selector"),
                  ["find", "findNext", "findPrevious", "findHide", "selectionForFind"].contains(name) else {
                throw UmiError.badRequest("selector is find, findNext, findPrevious, findHide or selectionForFind")
            }
            var responder: NSView = web
            if let pane = params.string("pane") {
                guard let surface = UmiTopology.allSurfaces.first(where: { $0.umiID == pane }) else { throw UmiError.notFound("no pane \(pane)") }
                responder = surface
            }
            guard let window = responder.window else { throw UmiError.failed("the view isn't in a window") }
            window.makeFirstResponder(responder)
            let performed = (window.firstResponder ?? responder).tryToPerform(NSSelectorFromString(name + ":"), with: nil)
            try? await Task.sleep(nanoseconds: 150_000_000)
            return ["performed": performed]
        default:
            break
        }
        let call: String
        var arguments: [String: Any] = [:]
        switch action {
        case "state": call = "return umiMarkdown.state()"
        case "style":
            call = "return umiMarkdown.style(selector, props)"
            arguments = ["selector": params.string("selector") ?? "body",
                         "props": (params.string("props") ?? "").split(separator: ",").map(String.init)]
        case "click":
            call = "return umiMarkdown.click(selector, nth)"
            arguments = ["selector": params.string("selector") ?? "", "nth": params.int("nth") ?? 0]
        case "find_type":
            // Text typed into the find field.
            call = "return umiMarkdown.typeInFind(text)"
            arguments = ["text": params.string("text") ?? ""]
        case "key":
            // A key pressed in the page (Escape, Enter, shift+Enter), as the page receives it.
            call = "return umiMarkdown.key(name, shift)"
            arguments = ["name": params.string("name") ?? "", "shift": params.bool("shift") ?? false]
        default: throw UmiError.badRequest("action is state, style, click, find_type, key, menu, perform or pasteboard")
        }
        let result = try await web.callAsyncJavaScript(call, arguments: arguments, in: nil, contentWorld: UmiCommentsUI.world)
        if let object = result as? [String: Any] { return object }
        return ["result": result ?? NSNull()]
    }
}
