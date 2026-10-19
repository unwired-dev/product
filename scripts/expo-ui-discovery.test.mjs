import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

test('Expo UI discovery lists exported shapes rather than their module name', () => {
  const project = mkdtempSync(join(tmpdir(), 'expo-ui-discovery-'));
  const pkg = join(project, 'node_modules/@expo/ui');
  const write = (name, content) => {
    const file = join(pkg, name);
    mkdirSync(join(file, '..'), { recursive: true });
    writeFileSync(file, content);
  };
  try {
    write('package.json', '{"version":"57.0.25"}');
    write(
      'build/swift-ui/index.d.ts',
      `
export * from './Shapes';
export * from './Nested';
export { TextField, type TextFieldProps } from './TextField';
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
export * from './index';
`,
    );
    write(
      'build/swift-ui/Nested/index.d.ts',
      'export declare const Capsule: unknown;',
    );
    write(
      'build/swift-ui/modifiers/index.d.ts',
      '/**\n * Sets padding.\n */\nexport declare function padding(): unknown;',
    );

    const script = new URL(
      '../.agents/skills/expo-ui/scripts/list-components.js',
      import.meta.url,
    );
    for (const flags of [[], ['--docs']]) {
      const output = execFileSync(
        process.execPath,
        [script.pathname, project, ...flags],
        { encoding: 'utf8' },
      );
      assert.match(output, /@expo\/ui 57\.0\.25/);
      assert.match(
        output,
        /Components: Button, Capsule, Circle, Rectangle, TextField/,
      );
      assert.doesNotMatch(
        output,
        /Components:.*(?:Shapes|Nested|Props|InternalButton)/,
      );
      assert.match(output, /padding/);
      if (flags.length) assert.match(output, /Sets padding/);
    }
  } finally {
    rmSync(project, { recursive: true, force: true });
  }
});
