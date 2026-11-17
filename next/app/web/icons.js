// File-type icons, colored by language as Warp's are: Material Icon Theme's SVGs (MIT,
// web/icons/LICENSE.md), the same set and mapping as Umi's UmiFileIcons.swift.
//
//   Umi.icons.file(name)     → 'icons/markdown.svg'
//   Umi.icons.img(name, 16)  → an <img> for a file name
//   Umi.icons.svg.chevronRight / chevronDown / folder / search / …  inline SVG strings (SF Symbol look)
'use strict';
window.Umi = window.Umi || {};

Umi.icons = (() => {
  const NAMES = {
    dockerfile: 'docker', containerfile: 'docker', '.gitignore': 'git', '.gitattributes': 'git', '.gitmodules': 'git',
    build: 'bazel', workspace: 'bazel', 'build.bazel': 'bazel', 'workspace.bazel': 'bazel',
    '.bashrc': 'console', '.bash_profile': 'console', '.zshrc': 'console', '.zprofile': 'console', '.zsh_profile': 'console', '.profile': 'console',
    'package-lock.json': 'lock', 'yarn.lock': 'lock', 'cargo.lock': 'lock', 'pnpm-lock.yaml': 'lock', 'package.resolved': 'lock',
  };
  const EXT = {};
  const add = (icon, exts) => exts.split(' ').forEach((e) => { EXT[e] = icon; });
  add('swift', 'swift'); add('python', 'py py3 pyw pyi'); add('javascript', 'js cjs mjs'); add('typescript', 'ts cts mts');
  add('react', 'jsx'); add('react_ts', 'tsx'); add('json', 'json jsonc jsonl'); add('markdown', 'md markdown mdown mkd mkdn mdx');
  add('rust', 'rs'); add('go', 'go'); add('c', 'c'); add('cpp', 'cpp cxx cc c++'); add('h', 'h'); add('hpp', 'hpp hh hxx h++');
  add('java', 'java groovy gvy gy gsh'); add('ruby', 'rb'); add('html', 'html htm'); add('css', 'css'); add('csharp', 'cs');
  add('php', 'php phtml'); add('scala', 'scala sbt sc'); add('kotlin', 'kt kts'); add('lua', 'lua'); add('yaml', 'yml yaml');
  add('toml', 'toml'); add('xml', 'xml plist'); add('docker', 'dockerfile'); add('elixir', 'ex exs'); add('terraform', 'tf tfvars hcl');
  add('database', 'sql'); add('console', 'sh zsh bash fish command'); add('powershell', 'ps1 pwsh'); add('nix', 'nix'); add('vue', 'vue');
  add('bazel', 'bzl bazel'); add('table', 'csv tsv'); add('log', 'log'); add('settings', 'ini conf cfg env properties'); add('lock', 'lock');
  add('image', 'png jpg jpeg gif webp heic ico bmp tiff'); add('svg', 'svg'); add('pdf', 'pdf'); add('zip', 'zip tar gz tgz xz bz2 7z');

  function iconName(fileName) {
    const lower = fileName.toLowerCase();
    if (NAMES[lower]) return NAMES[lower];
    if (lower.startsWith('dockerfile.') || lower.startsWith('containerfile.')) return 'docker';
    const dot = lower.lastIndexOf('.');
    // A leading dot alone is a dotfile's name, not an extension (as NSString.pathExtension).
    const ext = dot > 0 ? lower.slice(dot + 1) : '';
    return EXT[ext] || 'document';
  }

  const file = (name) => `icons/${iconName(name.split('/').pop())}.svg`;

  function img(name, size = 16) {
    const el = document.createElement('img');
    el.className = 'file-icon';
    el.src = file(name);
    el.width = el.height = size;
    el.alt = '';
    el.draggable = false;
    return el;
  }

  const sv = (body, vb = '0 0 16 16', extra = '') =>
    `<svg viewBox="${vb}" width="16" height="16" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" ${extra}>${body}</svg>`;
  const svg = {
    chevronRight: sv('<path d="M6.5 4.5 10 8l-3.5 3.5" stroke-width="1.6"/>'),
    chevronDown: sv('<path d="M4.5 6.5 8 10l3.5-3.5" stroke-width="1.6"/>'),
    folder: sv('<path d="M2 4.6c0-.6.5-1.1 1.1-1.1h3l1.4 1.5h5.4c.6 0 1.1.5 1.1 1.1v6.3c0 .6-.5 1.1-1.1 1.1H3.1c-.6 0-1.1-.5-1.1-1.1z" stroke-width="1.1"/>'),
    search: sv('<circle cx="7" cy="7" r="4.3" stroke-width="1.3"/><path d="m10.2 10.2 3.3 3.3" stroke-width="1.3"/>'),
    tabs: sv('<rect x="2.5" y="5" width="11" height="8.5" rx="1.5" stroke-width="1.1"/><path d="M4 3h8" stroke-width="1.1"/>'),
    caseToggle: sv('<path d="M1.8 12 4.6 4.2h.6L8 12M2.8 9.4h4.2" stroke-width="1.3"/><path d="M13.6 8.6v3.4M13.6 9.9c0-.9-.8-1.5-1.8-1.5s-1.9.7-1.9 1.8.8 1.8 1.9 1.8 1.8-.6 1.8-1.5" stroke-width="1.2"/>'),
    regexToggle: sv('<path d="M5.5 4 2.5 8l3 4M10.5 4l3 4-3 4M9 3.5 7 12.5" stroke-width="1.3"/>'),
    warning: sv('<path d="M8 2.2 14.3 13H1.7z" fill="currentColor" stroke="none"/><path d="M8 6.3v3.2" stroke="#000" stroke-width="1.3"/><circle cx="8" cy="11.2" r=".75" fill="#000" stroke="none"/>'),
    plusCircle: sv('<circle cx="8" cy="8" r="5.6" stroke-width="1.2"/><path d="M8 5.4v5.2M5.4 8h5.2" stroke-width="1.2"/>'),
    doc: sv('<path d="M4 2.5h5l3 3v8H4z M9 2.5v3h3" stroke-width="1.1"/>'),
    docText: sv('<path d="M4 2.5h5l3 3v8H4z M9 2.5v3h3 M6 8.5h4M6 10.5h4" stroke-width="1.1"/>'),
    code: sv('<path d="M5 4.5 1.8 8 5 11.5M11 4.5 14.2 8 11 11.5M9.3 3.5 6.7 12.5" stroke-width="1.2"/>'),
    braces: sv('<path d="M6 3c-1.5 0-1.8.6-1.8 1.8v1.4c0 1-.5 1.6-1.4 1.8.9.2 1.4.8 1.4 1.8v1.4c0 1.2.3 1.8 1.8 1.8M10 3c1.5 0 1.8.6 1.8 1.8v1.4c0 1 .5 1.6 1.4 1.8-.9.2-1.4.8-1.4 1.8v1.4c0 1.2-.3 1.8-1.8 1.8" stroke-width="1.1"/>'),
    photo: sv('<rect x="2" y="3.5" width="12" height="9" rx="1.5" stroke-width="1.1"/><path d="m3 11.5 3.2-3.2 2.3 2.3 1.5-1.5 3 2.4" stroke-width="1.1"/><circle cx="10.5" cy="6.3" r="1" stroke-width="1"/>'),
    globe: sv('<circle cx="8" cy="8" r="5.8" stroke-width="1.1"/><path d="M2.2 8h11.6M8 2.2c1.6 1.6 2.3 3.6 2.3 5.8S9.6 12.2 8 13.8C6.4 12.2 5.7 10.2 5.7 8S6.4 3.8 8 2.2z" stroke-width="1.1"/>'),
  };

  // Quick open's row icon, as Umi's palette (UmiPaletteFileIcon): a plain glyph by file type.
  function glyph(path) {
    const dot = path.lastIndexOf('.'), ext = dot > path.lastIndexOf('/') + 1 ? path.slice(dot + 1).toLowerCase() : '';
    if (['md', 'markdown', 'txt', 'rst'].includes(ext)) return svg.docText;
    if (['swift', 'zig', 'rs', 'go', 'c', 'h', 'cpp', 'm', 'py', 'rb', 'js', 'ts', 'tsx', 'jsx', 'java', 'kt', 'sh', 'zsh', 'bash'].includes(ext)) return svg.code;
    if (['json', 'yaml', 'yml', 'toml', 'xml', 'plist', 'conf', 'ini'].includes(ext)) return svg.braces;
    if (['png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'icns', 'pdf'].includes(ext)) return svg.photo;
    if (['html', 'css'].includes(ext)) return svg.globe;
    return svg.doc;
  }

  return { iconName, file, img, svg, glyph };
})();
