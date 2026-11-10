// Print the licence each CocoaPods pod and resolved Swift package in an archive
// build declares or ships. This records declarations; it does not decide
// licence compatibility or produce the notices the build owes (#1962).
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { argv, exit, stderr, stdout } from 'node:process';

import * as Schema from 'effect/Schema';

const Acknowledgements = Schema.Struct({
  PreferenceSpecifiers: Schema.Array(
    Schema.Struct({
      Title: Schema.String,
      License: Schema.optional(Schema.String),
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
  fail('usage: native-licence-inventory.mjs <Pods> <SourcePackages>');
}
const pods = path.resolve(argv.at(2));
const packages = path.resolve(argv.at(3));

// Root pods and their versions, from the installed lockfile's PODS section.
const lock = path.join(pods, 'Manifest.lock');
const installed = new Map(
  [
    ...(
      /^PODS:\n(?<section>(?:[ ].*\n)*)/mu.exec(read(lock))?.groups.section ??
      fail(`unreadable ${lock}: no PODS section`)
    ).matchAll(/^ {2}- "?(?<name>[^/ "]+)[^ "]* \((?<version>[^)]+)\)/gmu),
  ].map(({ groups }) => [groups.name, groups.version]),
);
// CocoaPods acknowledges the pods whose licence text it found.
const acknowledged = new Map(
  plist(
    Acknowledgements,
    path.join(
      pods,
      'Target Support Files/Pods-UnwiredMail/Pods-UnwiredMail-acknowledgements.plist',
    ),
  ).PreferenceSpecifiers.map(({ Title, License }) => [Title, License ?? null]),
);
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
  acknowledged.get(name) ?? podspecLicence(name) ?? null;

// Order by name, then version, in code units, independent of the locale.
const order = (a, b) => (a < b ? -1 : Number(a > b));
const podList = [...installed]
  .map(([name, version]) => ({
    name,
    version,
    licence: declared(name),
    licenceText: acknowledged.has(name),
  }))
  .toSorted((a, b) => order(a.name, b.name));

// Swift packages declare no licence, so only their shipped files are listed.
const stateFile = path.join(packages, 'workspace-state.json');
const swiftList = decode(WorkspaceState, stateFile, read(stateFile))
  .object.dependencies.map(({ packageRef, state, subpath }) => {
    const checkout = path.join(packages, 'checkouts', subpath);
    if (!existsSync(checkout)) {
      fail(`missing checkout ${checkout}`);
    }
    return {
      identity: packageRef.identity,
      location: packageRef.location,
      version: state.checkoutState.version ?? null,
      revision: state.checkoutState.revision,
      licenceFiles: readdirSync(checkout)
        .filter((file) =>
          /^(?:licen[cs]e|copying|notice)(?:$|[.-])/iu.test(file),
        )
        .toSorted(),
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
