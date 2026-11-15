// Print the licence each CocoaPods pod and resolved Swift package in an archive
// build declares or ships. This records declarations; it does not decide
// licence compatibility or produce the notices the build owes (#1962).
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { argv, exit, stderr, stdout } from 'node:process';

import * as Schema from 'effect/Schema';

import { noticeFiles } from './notice-files.mjs';

const Acknowledgements = Schema.Struct({
  PreferenceSpecifiers: Schema.Array(
    Schema.Struct({
      Title: Schema.String,
      License: Schema.optional(Schema.String),
      FooterText: Schema.optional(Schema.String),
    }),
  ),
});
// A podspec declares a licence as its type or as an object with a type.
const Podspec = Schema.Struct({
  license: Schema.optional(
    Schema.Union([
      Schema.String,
      Schema.Struct({ type: Schema.optional(Schema.String) }),
    ]),
  ),
});
const WorkspaceState = Schema.Struct({
  object: Schema.Struct({
    dependencies: Schema.Array(
      Schema.Struct({
        packageRef: Schema.Struct({
          identity: Schema.String,
          location: Schema.String,
        }),
        state: Schema.Struct({
          checkoutState: Schema.Struct({
            revision: Schema.String,
            version: Schema.optional(Schema.String),
          }),
        }),
        subpath: Schema.String,
      }),
    ),
  }),
});

const fail = (message) => {
  stderr.write(`native-licence-inventory: ${message}\n`);
  exit(1);
};

const decode = (schema, file, text) => {
  try {
    return Schema.decodeSync(Schema.fromJsonString(schema))(text);
  } catch (error) {
    return fail(`unreadable ${file}: ${error.message}`);
  }
};
const read = (file) => {
  try {
    return readFileSync(file, 'utf8');
  } catch (error) {
    return fail(`unreadable ${file}: ${error.message}`);
  }
};
const plist = (schema, file) => {
  const result = spawnSync('plutil', ['-convert', 'json', '-o', '-', file], {
    encoding: 'utf8',
  });
  return result.status === 0
    ? decode(schema, file, result.stdout)
    : fail(`unreadable ${file}: ${result.stderr.trim()}`);
};

if (!argv.at(3)) {
  fail(
    'usage: native-licence-inventory.mjs <Pods> <SourcePackages> [--include-text]',
  );
}
const pods = path.resolve(argv.at(2));
const packages = path.resolve(argv.at(3));
const includeText = argv.includes('--include-text');

// Root pods and their versions, from the installed lockfile's PODS section.
const lock = path.join(pods, 'Manifest.lock');
const manifest = read(lock);
const installed = new Map(
  [
    ...(
      /^PODS:\n(?<section>(?:[ ].*\n)*)/mu.exec(manifest)?.groups.section ??
      fail(`unreadable ${lock}: no PODS section`)
    ).matchAll(/^ {2}- "?(?<name>[^/ "]+)[^ "]* \((?<version>[^)]+)\)/gmu),
  ].map(({ groups }) => [groups.name, groups.version]),
);
// Pods installed from a local path alone, relative to the Podfile beside Pods.
// CocoaPods prefers another source key, such as :podspec:, over :path:.
const localPaths = new Map(
  [
    ...(
      /^EXTERNAL SOURCES:\n(?<section>(?:[ ].*\n)*)/mu.exec(manifest)?.groups
        .section ?? ''
    ).matchAll(
      /^ {2}"?(?<name>[^":]+)"?:\n {4}:path: (?<q>["']?)(?<path>.+)\k<q>$(?!\n {4})/gmu,
    ),
  ].map(({ groups }) => {
    const local = path.resolve(path.dirname(pods), groups.path);
    return existsSync(local)
      ? [groups.name, local]
      : fail(`missing pod path ${local}`);
  }),
);
// CocoaPods acknowledges the pods whose licence text it found.
const acknowledgementsFile = path.join(
  pods,
  'Target Support Files/Pods-UnwiredMail/Pods-UnwiredMail-acknowledgements.plist',
);
const acknowledged = new Map(
  [...installed.keys()].map((name) => [name, { licence: null, text: '' }]),
);
for (const { Title, License, FooterText } of plist(
  Acknowledgements,
  acknowledgementsFile,
).PreferenceSpecifiers) {
  acknowledged.set(Title, { licence: License ?? null, text: FooterText ?? '' });
}
// Pods from a path or Git source keep their podspec in the Pods folder.
const podspecLicence = (name) => {
  const file = path.join(pods, 'Local Podspecs', `${name}.podspec.json`);
  if (!existsSync(file)) {
    return undefined;
  }
  const { license } = decode(Podspec, file, read(file));
  return typeof license === 'string' ? license : license?.type;
};
const declared = (name) =>
  acknowledged.get(name).licence ?? podspecLicence(name) ?? null;
const licenceTexts = (directory, recursive = false) =>
  noticeFiles(directory, recursive).map(({ file, text }) => ({
    file: path.join(directory, file),
    text,
  }));
// CocoaPods looks for licence text only beside the podspec. Path pods can
// also use the notices supplied up to their npm package root.
const localLicenceTexts = (directory) => [
  ...licenceTexts(directory),
  ...(!existsSync(path.join(directory, 'package.json')) &&
  path.dirname(directory) !== directory
    ? localLicenceTexts(path.dirname(directory))
    : []),
];
const podNoticeTexts = (name) => {
  const { text } = acknowledged.get(name);
  if (text.trim()) {
    return [{ file: `${acknowledgementsFile}#${name}`, text }];
  }
  return localPaths.has(name) ? localLicenceTexts(localPaths.get(name)) : [];
};

// Order by name, then version, in code units, independent of the locale.
const order = (a, b) => (a < b ? -1 : Number(a > b));
const podList = [...installed]
  .map(([name, version]) => {
    const noticeTexts = podNoticeTexts(name);
    return {
      name,
      version,
      licence: declared(name),
      licenceText: noticeTexts.length > 0,
      ...(includeText ? { noticeTexts } : {}),
    };
  })
  .toSorted((a, b) => order(a.name, b.name));

// Swift packages declare no licence, so only their shipped files are listed.
const stateFile = path.join(packages, 'workspace-state.json');
const swiftList = decode(WorkspaceState, stateFile, read(stateFile))
  .object.dependencies.map(({ packageRef, state, subpath }) => {
    const checkout = path.join(packages, 'checkouts', subpath);
    if (!existsSync(checkout)) {
      return fail(`missing checkout ${checkout}`);
    }
    return {
      identity: packageRef.identity,
      location: packageRef.location,
      version: state.checkoutState.version ?? null,
      revision: state.checkoutState.revision,
      licenceFiles: licenceTexts(checkout)
        .map(({ file }) => path.basename(file))
        .toSorted(),
      ...(includeText ? { noticeTexts: licenceTexts(checkout, true) } : {}),
    };
  })
  .toSorted((a, b) => order(a.identity, b.identity));

const podId = ({ name, version }) => `${name}@${version}`;
const swiftId = ({ identity, version, revision }) =>
  `${identity}@${version ?? revision}`;

stdout.write(
  `${JSON.stringify(
    {
      pods: podList,
      swiftPackages: swiftList,
      undeclared: podList.filter((pod) => pod.licence === null).map(podId),
      withoutLicenceText: [
        ...podList.filter((pod) => !pod.licenceText).map(podId),
        ...swiftList
          .filter((item) => item.licenceFiles.length === 0)
          .map(swiftId),
      ],
    },
    null,
    2,
  )}\n`,
);
