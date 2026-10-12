import { extendOxfmtConfig } from '@rajzik/oxfmt-config';

export default extendOxfmtConfig({
  ignorePatterns: [
    '**/convex/_generated/**',
    // run.py and report.py generate the System Category benchmark results.
    'tools/system-category-benchmark/results/**',
    // Agent tools such as graft and turbo rewrite their managed AGENTS.md blocks.
    '**/AGENTS.md',
    // Icon Composer owns this document's layout.
    'apps/unwired-mail/unwired-mail/AppIcon.icon/icon.json',
  ],
});
