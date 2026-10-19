import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

test('Expo UI discovery lists wildcard and multiline exports from paths with spaces', () => {
  const project = mkdtempSync(path.join(tmpdir(), 'expo-ui-discovery-'));
  const pkg = path.join(project, 'node_modules/@expo/ui');
  const write = (name, content) => {
    const file = path.join(pkg, name);
    mkdirSync(path.join(file, '..'), { recursive: true });
    writeFileSync(file, content);
  };
  try {
    write('package.json', '{"version":"57.0.25"}');
    write(
      'build/swift-ui/index.d.ts',
      `
export * from './Shapes';
export * from './Nested';
export {
  TextField,
  type TextFieldProps,
  type TextFieldRef,
} from './TextField';
export type { GhostComponent } from './Types';
export { InternalButton as Button } from './Button';
`,
    );
    write(
      'build/swift-ui/Shapes.d.ts',
      `
export declare const Rectangle: unknown;
export declare function Circle(): unknown;
export interface ShapeProps {}
export type ShapeValue = string;
export * from './Cycle';
`,
    );
    write(
      'build/swift-ui/Nested/index.d.ts',
      'export declare const Capsule: unknown;',
    );
    write('build/swift-ui/Cycle.d.ts', "export * from './Shapes';");
    write(
      'build/jetpack-compose/index.d.ts',
      `
export {
  HorizontalPager,
  type HorizontalPagerProps,
} from './HorizontalPager';
`,
    );
    write(
      'build/swift-ui/modifiers/index.d.ts',
      '/**\n * Sets padding.\n */\nexport declare function padding(): unknown;',
    );

    const scriptPath = path.join(
      project,
      'skill with spaces',
      'list-components.cjs',
    );
    mkdirSync(path.dirname(scriptPath), { recursive: true });
    copyFileSync(
      new URL(
        '../.agents/skills/expo-ui/scripts/list-components.js',
        import.meta.url,
      ),
      scriptPath,
    );
    const script = pathToFileURL(scriptPath);
    for (const flags of [[], ['--docs']]) {
      const output = execFileSync(
        process.execPath,
        [fileURLToPath(script), project, ...flags],
        { encoding: 'utf8' },
      );
      assert.match(output, /@expo\/ui 57\.0\.25/u);
      assert.match(
        output,
        /Components: Button, Capsule, Circle, Rectangle, TextField/u,
      );
      assert.doesNotMatch(
        output,
        /Components:.*(?:Shapes|Nested|Props|InternalButton|GhostComponent)/u,
      );
      assert.match(output, /Components: HorizontalPager/u);
      assert.match(output, /padding/u);
      if (flags.length) {
        assert.match(output, /Sets padding/u);
      }
    }
  } finally {
    rmSync(project, { recursive: true, force: true });
  }
});
