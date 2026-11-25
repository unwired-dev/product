import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';
import { PNG } from 'pngjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const device = 'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro';

// A 20x20 grey image; `block` paints a 10x10 black square, a quarter of its pixels.
function image(block = false, size = 20) {
  const png = new PNG({ width: size, height: size });
  for (let index = 0; index < png.data.length; index += 4) {
    const pixel = index / 4;
    const dark = block && pixel % size < 10 && pixel / size < 10;
    png.data.fill(dark ? 0 : 200, index, index + 3);
    png.data[index + 3] = 255;
  }
  return PNG.sync.write(png);
}
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

// Each case runs the report on one capture; anything missing, altered or unaligned must leave the
// report incomplete and fail, while a deviation or regression is reported without failing.
const cases = [
  ['matching capture', {}, 0, 'complete', 'conforms', 'matches'],
  [
    'changed capture',
    { actual: image(true) },
    0,
    'complete',
    'deviates',
    'regressed',
  ],
  [
    'missing capture',
    { actual: null },
    1,
    'incomplete',
    'incomplete',
    'incomplete',
  ],
  [
    'unreviewed baseline',
    { baseline: false },
    1,
    'incomplete',
    'conforms',
    'incomplete',
  ],
  [
    'altered reference',
    { figmaBytes: image(true) },
    1,
    'incomplete',
    'failed',
    'matches',
  ],
  [
    'unaligned capture',
    { actual: image(false, 24) },
    1,
    'incomplete',
    'failed',
    'failed',
  ],
];

for (const [name, change, exit, status, figma, baseline] of cases) {
  test(`visual report: ${name}`, () => {
    mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
    const directory = mkdtempSync(path.join(root, 'scratchpad/visual-report-'));
    try {
      const reference = image();
      const references = path.join(directory, 'visual');
      mkdirSync(path.join(references, 'figma'), { recursive: true });
      mkdirSync(path.join(references, 'baseline'), { recursive: true });
      writeFileSync(
        path.join(references, 'figma/inbox.png'),
        change.figmaBytes ?? reference,
      );
      writeFileSync(path.join(references, 'baseline/inbox.png'), reference);
      const tolerance = { threshold: 0.1, maxDiffRatio: 0.01, reason: 'test' };
      const capture = {
        id: 'inbox-light',
        device,
        attachment: 'Visual Inbox (light)',
        figma: {
          image: 'figma/inbox.png',
          sha256: sha256(reference),
          fileKey: 'file',
          nodeId: '1:2',
          frame: 'Inbox · Light',
          section: 'Approved',
          fileVersion: null,
          scale: 1,
          exportedAt: '2026-11-25T00:00:00Z',
          approvedDifferences: [],
          outstandingDeviations: [],
        },
        ...(change.baseline !== false && {
          baseline: {
            image: 'baseline/inbox.png',
            sha256: sha256(reference),
            appRevision: 'abc',
            capturedIn: 'test',
            reviewedIn: 'test',
            environment: {},
          },
        }),
      };
      writeFileSync(
        path.join(references, 'inbox.json'),
        JSON.stringify({
          tolerances: { figma: tolerance, baseline: tolerance },
          captures: [capture],
        }),
      );
      const attachments = path.join(directory, 'attachments');
      mkdirSync(attachments);
      const exported = [];
      if (change.actual !== null) {
        writeFileSync(
          path.join(attachments, 'shot.png'),
          change.actual ?? reference,
        );
        exported.push({
          exportedFileName: 'shot.png',
          suggestedHumanReadableName: 'Visual Inbox (light)_0_ABC.png',
        });
      }
      writeFileSync(
        path.join(attachments, 'manifest.json'),
        JSON.stringify([
          {
            testIdentifier: 'InboxTests/testInboxVisual()',
            attachments: exported,
          },
        ]),
      );
      const out = path.join(directory, 'report');
      const result = spawnSync(
        process.execPath,
        [
          path.join(root, 'scripts/visual-report.mjs'),
          '--manifest',
          path.join(references, 'inbox.json'),
          '--device',
          device,
          '--attachments',
          attachments,
          '--out',
          out,
        ],
        { encoding: 'utf8' },
      );
      assert.equal(result.status, exit, result.stderr);
      const report = Schema.decodeUnknownSync(Schema.UnknownFromJsonString)(
        readFileSync(path.join(out, 'result.json'), 'utf8'),
      );
      assert.equal(report.status, status);
      assert.equal(report.captures[0].figma.status, figma);
      assert.equal(report.captures[0].baseline.status, baseline);
      if (figma === 'deviates') {
        assert.equal(report.captures[0].figma.ratio, 0.25);
        assert.equal(report.figmaDeviations.length, 1);
        assert.equal(report.baselineRegressions.length, 1);
      }
      const artifact = (file) =>
        existsSync(path.join(out, 'inbox-light', file));
      assert.equal(artifact('actual.png'), change.actual !== null);
      assert.equal(
        artifact('figma/reference.png'),
        change.figmaBytes === undefined,
      );
      for (const file of ['figma/overlay.png', 'figma/diff.png']) {
        assert.equal(
          artifact(file),
          figma === 'conforms' || figma === 'deviates',
          file,
        );
      }
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}
