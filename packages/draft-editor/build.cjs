const { mkdirSync, writeFileSync } = require('node:fs');
const path = require('node:path');

const { buildSync } = require('esbuild');

// Bundles the editor into one HTML page that loads nothing: its script and styles are inline,
// and its Content Security Policy refuses every other source and connection.
const policy = [
  "default-src 'none'",
  "script-src 'unsafe-inline'",
  "style-src 'unsafe-inline'",
].join('; ');
const style = `
:root { color-scheme: light dark; }
html, body { margin: 0; min-height: 100%; background: transparent; }
body { font: -apple-system-body; -webkit-text-size-adjust: 100%; }
.ProseMirror { min-height: 100vh; box-sizing: border-box; padding: 12px 16px; outline: none; white-space: pre-wrap; overflow-wrap: anywhere; }
.ProseMirror p { margin: 0 0 0.75em; }
.ProseMirror h1, .ProseMirror h2, .ProseMirror h3 { margin: 0 0 0.5em; line-height: 1.25; }
.ProseMirror h1 { font-size: 1.6em; }
.ProseMirror h2 { font-size: 1.35em; }
.ProseMirror h3 { font-size: 1.15em; }
.ProseMirror ul, .ProseMirror ol { margin: 0 0 0.75em; padding-left: 1.5em; }
.ProseMirror li p, .ProseMirror blockquote p { margin: 0; }
.ProseMirror blockquote { margin: 0 0 0.75em; padding-left: 12px; border-left: 3px solid rgba(128, 128, 128, 0.5); }
.ProseMirror pre { margin: 0; padding: 0 8px; background: rgba(128, 128, 128, 0.12); white-space: pre-wrap; }
.ProseMirror pre + :not(pre) { margin-top: 0.75em; }
.ProseMirror code, .ProseMirror pre { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
`;

function pageHtml() {
  const [script] = buildSync({
    entryPoints: [path.join(__dirname, 'src/editor.ts')],
    bundle: true,
    format: 'iife',
    minify: true,
    target: 'safari18',
    write: false,
  }).outputFiles;
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${policy}"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${style}</style></head><body><div id="editor"></div><script>${script.text.replaceAll('</script', String.raw`<\/script`)}</script></body></html>`;
}

// Writes the page as the module Metro substitutes for `src/page.ts`, and returns its path.
function buildPage() {
  const output = path.join(__dirname, 'dist/page.js');
  mkdirSync(path.dirname(output), { recursive: true });
  writeFileSync(
    output,
    `export const editorPage = ${JSON.stringify(pageHtml())};\n`,
  );
  return output;
}

module.exports = { buildPage, pageHtml };
