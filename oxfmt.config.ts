import { extendOxfmtConfig } from '@rajzik/oxfmt-config';

export default extendOxfmtConfig({
  ignorePatterns: [
    // Preserve the pinned upstream Expo skill bundles.
    '.agents/skills/expo-ui/**',
    '.agents/skills/expo-router/**',
    '**/convex/_generated/**',
    // run.py and report.py generate the System Category benchmark results.
    'tools/system-category-benchmark/results/**',
    // custom.py generates the Custom Category results, tables and golden outputs.
    'tools/system-category-benchmark/custom/results/**',
    'tools/system-category-benchmark/custom/tables.md',
    'tools/system-category-benchmark/custom/golden-v1.json',
    // Agent tools such as graft and turbo rewrite their managed AGENTS.md blocks.
    '**/AGENTS.md',
    // Icon Composer owns this document's layout.
    'apps/unwired-mail/unwired-mail/AppIcon.icon/icon.json',
  ],
});
