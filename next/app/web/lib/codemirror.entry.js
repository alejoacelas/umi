// What lib/codemirror.js is built from: CodeMirror 6 (state 6.7.6, view 6.43.15, language 6.13.1,
// commands 6.11.1, search 6.7.2) and the languages below, as one script that sets window.CM, so
// the web layer needs no bundler. Rebuild in a scratch folder:
//   npm i esbuild @codemirror/{state,view,commands,language,search,lang-markdown,lang-javascript,\
//     lang-json,lang-python,lang-css,lang-html,lang-rust,lang-cpp,lang-go,lang-java,lang-yaml,\
//     legacy-modes} @lezer/highlight
//   npx esbuild codemirror.entry.js --bundle --minify --format=iife --global-name=CM \
//     --target=safari16 --legal-comments=eof --outfile=codemirror.js
// Also in lib/: markdown-it 14.1.0 (its dist/markdown-it.min.js), and Umi's MarkdownAssets
// (highlight.js 11.10.0, Mermaid, Roboto).
export * as state from '@codemirror/state';
export * as view from '@codemirror/view';
export * as commands from '@codemirror/commands';
export * as language from '@codemirror/language';
export * as search from '@codemirror/search';
export { tags } from '@lezer/highlight';
import { StreamLanguage } from '@codemirror/language';
import { markdown } from '@codemirror/lang-markdown';
import { javascript } from '@codemirror/lang-javascript';
import { json } from '@codemirror/lang-json';
import { python } from '@codemirror/lang-python';
import { css } from '@codemirror/lang-css';
import { html } from '@codemirror/lang-html';
import { rust } from '@codemirror/lang-rust';
import { cpp } from '@codemirror/lang-cpp';
import { go } from '@codemirror/lang-go';
import { java } from '@codemirror/lang-java';
import { yaml } from '@codemirror/lang-yaml';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { swift } from '@codemirror/legacy-modes/mode/swift';
import { toml } from '@codemirror/legacy-modes/mode/toml';
import { ruby } from '@codemirror/legacy-modes/mode/ruby';
import { lua } from '@codemirror/legacy-modes/mode/lua';
import { csharp, kotlin, scala } from '@codemirror/legacy-modes/mode/clike';
import { dockerFile } from '@codemirror/legacy-modes/mode/dockerfile';

const legacy = (m) => () => StreamLanguage.define(m);
// name → language support factory
export const languages = {
  markdown: () => markdown(),
  javascript: () => javascript({ jsx: true }),
  typescript: () => javascript({ jsx: true, typescript: true }),
  json: () => json(),
  python: () => python(),
  css: () => css(),
  html: () => html(),
  rust: () => rust(),
  cpp: () => cpp(),
  go: () => go(),
  java: () => java(),
  yaml: () => yaml(),
  shell: legacy(shell),
  swift: legacy(swift),
  toml: legacy(toml),
  ruby: legacy(ruby),
  lua: legacy(lua),
  csharp: legacy(csharp),
  kotlin: legacy(kotlin),
  scala: legacy(scala),
  dockerfile: legacy(dockerFile),
};
