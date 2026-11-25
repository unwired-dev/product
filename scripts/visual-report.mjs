// Compares native visual captures with their pinned Figma frames and reviewed native baselines
// (docs/visual-report.md). In reporting mode a Figma deviation or baseline regression is reported,
// never fatal; a missing, unaligned or altered capture, reference or baseline leaves the report
// incomplete and exits 1, so it can never read as passing.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';

import * as Schema from 'effect/Schema';
import pixelmatch from 'pixelmatch';
import { PNG } from 'pngjs';

const Text = Schema.NonEmptyString;
const Tolerance = Schema.Struct({
  threshold: Schema.Finite,
  maxDiffRatio: Schema.Finite,
  reason: Text,
});
const Expected = {
  image: Text,
  sha256: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/u)),
};
const Manifest = Schema.Struct({
  tolerances: Schema.Struct({ figma: Tolerance, baseline: Tolerance }),
  captures: Schema.Array(
    Schema.Struct({
      id: Text,
      device: Text,
      attachment: Text,
      figma: Schema.optionalKey(
        Schema.Struct({
          ...Expected,
          fileKey: Text,
          nodeId: Text,
          frame: Text,
          section: Text,
          fileVersion: Schema.NullOr(Text),
          scale: Schema.Finite,
          exportedAt: Text,
          approvedDifferences: Schema.Array(Text),
          outstandingDeviations: Schema.Array(Text),
        }),
      ),
      baseline: Schema.optionalKey(
        Schema.Struct({
          ...Expected,
          appRevision: Text,
          capturedIn: Text,
          reviewedIn: Text,
          environment: Schema.Record(Schema.String, Schema.Unknown),
        }),
      ),
    }),
  ),
});
// The manifest.json that `xcrun xcresulttool export attachments` writes beside the files.
const Exported = Schema.Array(
  Schema.Struct({
    attachments: Schema.Array(
      Schema.Struct({
        exportedFileName: Text,
        suggestedHumanReadableName: Text,
      }),
    ),
  }),
);
const readJson = (schema, file) =>
  Schema.decodeSync(Schema.fromJsonString(schema))(readFileSync(file, 'utf8'));
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const { values } = parseArgs({
  options: {
    manifest: { type: 'string' },
    device: { type: 'string' },
    attachments: { type: 'string' },
    out: { type: 'string' },
    revision: { type: 'string', default: 'unknown' },
    toolchain: { type: 'string', default: 'unknown' },
  },
});
if (!values.manifest || !values.device || !values.attachments || !values.out) {
  throw new Error(
    'Usage: visual-report.mjs --manifest <file> --device <type> --attachments <dir> --out <dir>',
  );
}
const manifest = readJson(Manifest, values.manifest);
const references = path.dirname(values.manifest);
const exportedManifest = path.join(values.attachments, 'manifest.json');
const exported = existsSync(exportedManifest)
  ? readJson(Exported, exportedManifest).flatMap((test) => test.attachments)
  : [];
// XCTest suggests "<name>_<index>_<UUID>.<extension>" for a named attachment.
const attachment = (name) => {
  const found = exported.find(({ suggestedHumanReadableName: file }) =>
    file.startsWith(`${name}_`),
  );
  return found && path.join(values.attachments, found.exportedFileName);
};
const environmentFile = attachment('Visual environment');
const environment = {
  ...(environmentFile &&
    readJson(Schema.Record(Schema.String, Schema.Unknown), environmentFile)),
  toolchain: values.toolchain,
};
// The recorded environment fields a capture does not share; a baseline compares only within one.
const drift = (recorded) =>
  Object.keys({ ...recorded, ...environment }).filter(
    (key) => JSON.stringify(recorded[key]) !== JSON.stringify(environment[key]),
  );

const failures = [];
const incomplete = [];
const deviations = [];
const regressions = [];
const write = (file, png) => writeFileSync(file, PNG.sync.write(png));

function compare({ id, kind, expected, actual, directory }) {
  const label = `${id} ${kind}`;
  if (!expected) {
    incomplete.push(`${label}: no reviewed reference`);
    return { status: 'incomplete' };
  }
  const file = path.join(references, expected.image);
  if (!existsSync(file)) {
    failures.push(`${label}: ${expected.image} is missing`);
    return { status: 'failed' };
  }
  const bytes = readFileSync(file);
  if (sha256(bytes) !== expected.sha256) {
    failures.push(
      `${label}: ${expected.image} does not match its recorded sha256`,
    );
    return { status: 'failed' };
  }
  mkdirSync(directory, { recursive: true });
  writeFileSync(path.join(directory, 'reference.png'), bytes);
  if (!actual) {
    return { status: 'incomplete' };
  }
  const reference = PNG.sync.read(bytes);
  const { width, height } = reference;
  // Comparison never resizes: a capture that does not align with its reference fails.
  if (actual.width !== width || actual.height !== height) {
    failures.push(
      `${label}: capture ${actual.width}x${actual.height} does not align with ${width}x${height}`,
    );
    return { status: 'failed' };
  }
  const tolerance = manifest.tolerances[kind];
  const diff = new PNG({ width, height });
  const pixels = pixelmatch(
    reference.data,
    actual.data,
    diff.data,
    width,
    height,
    {
      threshold: tolerance.threshold,
    },
  );
  const overlay = new PNG({ width, height });
  for (let index = 0; index < overlay.data.length; index += 4) {
    for (let channel = 0; channel < 3; channel += 1) {
      overlay.data[index + channel] =
        (reference.data[index + channel] + actual.data[index + channel]) / 2;
    }
    overlay.data[index + 3] = 255;
  }
  write(path.join(directory, 'diff.png'), diff);
  write(path.join(directory, 'overlay.png'), overlay);
  const ratio = pixels / (width * height);
  const within = ratio <= tolerance.maxDiffRatio;
  const changed = kind === 'baseline' ? drift(expected.environment) : [];
  if (changed.length > 0) {
    incomplete.push(
      `${label}: captured with a different ${changed.join(', ')}`,
    );
    return { status: 'incomplete', differingPixels: pixels, ratio, tolerance };
  }
  if (!within) {
    (kind === 'figma' ? deviations : regressions).push(
      `${label}: ${(ratio * 100).toFixed(2)}% of pixels differ`,
    );
  }
  const [held, broken] =
    kind === 'figma' ? ['conforms', 'deviates'] : ['matches', 'regressed'];
  const status = within ? held : broken;
  return { status, differingPixels: pixels, ratio, tolerance };
}

const captures = manifest.captures
  .filter((capture) => capture.device === values.device)
  .map((capture) => {
    const directory = path.join(values.out, capture.id);
    mkdirSync(directory, { recursive: true });
    const file = attachment(capture.attachment);
    const bytes = file && readFileSync(file);
    const actual = bytes && PNG.sync.read(bytes);
    if (bytes) {
      writeFileSync(path.join(directory, 'actual.png'), bytes);
      // The provenance a reviewed baseline would record; nothing is ever promoted automatically.
      writeFileSync(
        path.join(directory, 'baseline-candidate.json'),
        `${JSON.stringify(
          {
            image: `baseline/${capture.id}.png`,
            sha256: sha256(bytes),
            appRevision: values.revision,
            environment,
          },
          null,
          2,
        )}\n`,
      );
    } else {
      failures.push(`${capture.id}: no "${capture.attachment}" capture`);
    }
    return {
      id: capture.id,
      actual: file ? `${capture.id}/actual.png` : null,
      figma: {
        ...compare({
          id: capture.id,
          kind: 'figma',
          expected: capture.figma,
          actual,
          directory: path.join(directory, 'figma'),
        }),
        provenance: capture.figma ?? null,
      },
      baseline: {
        ...compare({
          id: capture.id,
          kind: 'baseline',
          expected: capture.baseline,
          actual,
          directory: path.join(directory, 'baseline'),
        }),
        provenance: capture.baseline ?? null,
      },
    };
  });
if (captures.length > 0 && !environmentFile) {
  failures.push('no "Visual environment" attachment');
}
if (captures.length === 0) {
  incomplete.push(`${values.device}: the manifest lists no captures`);
}

const complete = failures.length === 0 && incomplete.length === 0;
const result = {
  mode: 'reporting',
  status: complete ? 'complete' : 'incomplete',
  device: values.device,
  revision: values.revision,
  environment,
  figmaDeviations: deviations,
  baselineRegressions: regressions,
  captureFailures: failures,
  incompleteCoverage: incomplete,
  captures,
};
mkdirSync(values.out, { recursive: true });
writeFileSync(
  path.join(values.out, 'result.json'),
  `${JSON.stringify(result, null, 2)}\n`,
);
const percent = ({ status, ratio }) =>
  ratio === undefined ? status : `${status} (${(ratio * 100).toFixed(2)}%)`;
const list = (title, items) =>
  `\n### ${title}\n\n${items.length === 0 ? 'None.' : items.map((item) => `- ${item}`).join('\n')}\n`;
writeFileSync(
  path.join(values.out, 'report.md'),
  [
    `## Visual report: ${values.device} (${result.status}, reporting mode)\n`,
    `Revision ${values.revision}\n`,
    '| Capture | Figma conformance | Native baseline |',
    '| --- | --- | --- |',
    ...captures.map(
      (capture) =>
        `| ${capture.id} | ${percent(capture.figma)} | ${percent(capture.baseline)} |`,
    ),
    list('Figma deviations', deviations),
    list('Native baseline regressions', regressions),
    list('Capture and export failures', failures),
    list('Incomplete coverage', incomplete),
  ].join('\n'),
);
process.stdout.write(readFileSync(path.join(values.out, 'report.md'), 'utf8'));
process.exitCode = complete ? 0 : 1;
