const fs = require('node:fs');
const path = require('node:path');
const { scenario } = require('../../../scripts/mock-mail-build.cjs');
const {
  withXcodeProject,
  withPodfile,
  withAppDelegate,
  withDangerousMod,
} = require('expo/config-plugins');

const privateInboxSource = (projectRoot) =>
  path.resolve(projectRoot, '../../native/private-inbox');

// Links the Swift packages Private Inbox's manifest pins by revision to the app target.
function addSwiftPackages(project, target, manifest) {
  const { objects } = project.hash.project;
  objects.XCRemoteSwiftPackageReference ??= {};
  objects.XCSwiftPackageProductDependency ??= {};
  const root = objects.PBXProject[project.hash.project.rootObject];
  root.packageReferences ??= [];
  const app = objects.PBXNativeTarget[target];
  app.packageProductDependencies ??= [];
  const frameworks = app.buildPhases.find(
    ({ value }) => objects.PBXFrameworksBuildPhase?.[value] !== undefined,
  );
  if (frameworks === undefined) {
    throw new Error('Private Inbox needs the app target Frameworks phase');
  }
  for (const [, url, revision] of manifest.matchAll(
    /url: "(?<url>[^"]+)",\s*revision: "(?<revision>[0-9a-f]{40})"/gu,
  )) {
    const name = path.basename(url, '.git');
    // Incremental prebuild also updates pins and repairs missing target links.
    let reference = Object.entries(objects.XCRemoteSwiftPackageReference).find(
      ([, packageReference]) => packageReference?.repositoryURL === `"${url}"`,
    )?.[0];
    if (reference === undefined) {
      reference = project.generateUuid();
      objects.XCRemoteSwiftPackageReference[reference] = {
        isa: 'XCRemoteSwiftPackageReference',
        repositoryURL: `"${url}"`,
      };
    }
    objects.XCRemoteSwiftPackageReference[reference].requirement = {
      kind: 'revision',
      revision,
    };
    if (!root.packageReferences.some(({ value }) => value === reference)) {
      root.packageReferences.push({ value: reference, comment: name });
    }
    const products = [
      ...manifest.matchAll(
        /\.product\(name: "(?<product>[^"]+)", package: "(?<package>[^"]+)"\)/gu,
      ),
    ].filter(({ groups }) => groups?.package === name);
    for (const { groups } of products) {
      const productName = groups?.product;
      let product = Object.entries(
        objects.XCSwiftPackageProductDependency,
      ).find(
        ([, dependency]) =>
          dependency?.package === reference &&
          dependency?.productName === productName,
      )?.[0];
      if (product === undefined) {
        product = project.generateUuid();
        objects.XCSwiftPackageProductDependency[product] = {
          isa: 'XCSwiftPackageProductDependency',
          package: reference,
          productName,
        };
      }
      if (
        !app.packageProductDependencies.some(({ value }) => value === product)
      ) {
        app.packageProductDependencies.push({
          value: product,
          comment: productName,
        });
      }
      const phase = objects.PBXFrameworksBuildPhase[frameworks.value];
      if (
        !phase.files.some(
          ({ value }) => objects.PBXBuildFile[value]?.productRef === product,
        )
      ) {
        const file = project.generateUuid();
        objects.PBXBuildFile[file] = {
          isa: 'PBXBuildFile',
          productRef: product,
        };
        objects.PBXBuildFile[`${file}_comment`] =
          `${productName} in Frameworks`;
        objects.PBXFrameworksBuildPhase[frameworks.value].files.push({
          value: file,
          comment: `${productName} in Frameworks`,
        });
      }
    }
  }
}

module.exports = function privateInbox(config) {
  const withGooglePod = withPodfile(config, (result) => {
    const declaration =
      "  pod 'GoogleSignIn', '10.0.0'\n  pod 'GoogleUtilities', :modular_headers => true\n  pod 'RecaptchaInterop', :modular_headers => true";
    if (!result.modResults.contents.includes(declaration)) {
      result.modResults.contents = result.modResults.contents.replace(
        /(?<target>target .* do)/u,
        `$<target>\n${declaration}`,
      );
    }
    return result;
  });
  const withGoogleCallback = withAppDelegate(withGooglePod, (result) => {
    const marker = 'if GIDSignIn.sharedInstance.handle(url) { return true }';
    if (!result.modResults.contents.includes(marker)) {
      result.modResults.contents = `import GoogleSignIn\n${result.modResults.contents}`;
      const anchor =
        'return super.application(app, open: url, options: options)';
      if (!result.modResults.contents.includes(anchor)) {
        throw new Error(
          'Google callback requires the Expo Swift AppDelegate URL handler',
        );
      }
      result.modResults.contents = result.modResults.contents.replace(
        anchor,
        `${marker}\n    ${anchor}`,
      );
    }
    return result;
  });
  // Content-free Gmail wakes reach the shared native queue; JavaScript settles each one.
  const withPushWakes = withAppDelegate(withGoogleCallback, (result) => {
    const marker = 'UnwiredPushWakes.registerDeviceToken(deviceToken)';
    if (!result.modResults.contents.includes(marker)) {
      const launch =
        'return super.application(application, didFinishLaunchingWithOptions: launchOptions)';
      const anchor = '  // Universal Links';
      if (
        !result.modResults.contents.includes(launch) ||
        !result.modResults.contents.includes(anchor)
      ) {
        throw new Error('Push wakes require the Expo Swift AppDelegate');
      }
      result.modResults.contents = result.modResults.contents
        .replace(
          launch,
          `application.registerForRemoteNotifications()\n    ${launch}`,
        )
        .replace(
          anchor,
          `  public override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    ${marker}
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  // Not forwarded to Expo's subscribers, so the system's handler completes exactly once.
  public override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    UnwiredPushWakes.receiveRemoteNotification(userInfo) { result in
      completionHandler(
        result == "synchronized" ? .newData : result == "ignored" ? .noData : .failed)
    }
  }

${anchor}`,
        );
    }
    return result;
  });
  // The workspace builds exactly the Swift package graph Private Inbox resolved.
  const withResolvedPackages = withDangerousMod(withPushWakes, [
    'ios',
    (result) => {
      const destination = path.join(
        result.modRequest.platformProjectRoot,
        `${result.modRequest.projectName}.xcworkspace/xcshareddata/swiftpm`,
      );
      fs.mkdirSync(destination, { recursive: true });
      fs.copyFileSync(
        path.join(
          privateInboxSource(result.modRequest.projectRoot),
          'Package.resolved',
        ),
        path.join(destination, 'Package.resolved'),
      );
      return result;
    },
  ]);
  const scenarioSetting = JSON.stringify(scenario ?? '');
  return withXcodeProject(withResolvedPackages, (result) => {
    const project = result.modResults;
    const target = project.getFirstTarget().uuid;
    for (const configuration of Object.values(
      project.pbxXCBuildConfigurationSection(),
    )) {
      if (configuration && configuration.buildSettings) {
        configuration.buildSettings.UNWIRED_MOCK_SCENARIO = scenarioSetting;
        const current = String(
          configuration.buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS ??
            '$(inherited)',
        )
          .replaceAll('"', '')
          .replaceAll('UNWIRED_REGISTRATION_MOCK', '')
          .replaceAll('UNWIRED_ASSISTANCE_MOCK', '')
          .trim();
        configuration.buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS =
          JSON.stringify(
            [
              current,
              scenario ? 'UNWIRED_ASSISTANCE_MOCK' : '',
              scenario?.startsWith('registration-')
                ? 'UNWIRED_REGISTRATION_MOCK'
                : '',
            ]
              .filter(Boolean)
              .join(' '),
          );
      }
    }
    const root = result.modRequest.platformProjectRoot;
    const destination = path.join(root, 'PrivateInbox');
    fs.mkdirSync(destination, { recursive: true });
    // Incremental prebuild keeps files and references an earlier build copied.
    const remove = (name) => {
      const relative = `PrivateInbox/${name}`;
      if (project.hasFile(relative)) {
        project.removeSourceFile(
          relative,
          { target },
          project.getFirstProject().firstProject.mainGroup,
        );
      }
      fs.rmSync(path.join(root, relative), { force: true });
    };
    // This fixture moved to the native tests.
    remove('SyntheticCredential.swift');
    // The synthetic registration backend now lives in TypeScript.
    remove('SyntheticRegistration.swift');
    const source = privateInboxSource(result.modRequest.projectRoot);
    addSwiftPackages(
      project,
      target,
      fs.readFileSync(path.join(source, 'Package.swift'), 'utf8'),
    );
    // Only registration Mock Mail Session builds compile the synthetic relay and providers.
    const registration = scenario?.startsWith('registration-') === true;
    if (!registration) {
      for (const name of fs.readdirSync(path.join(source, 'synthetic'))) {
        remove(name);
      }
    }
    for (const folder of [
      'Sources/PrivateInbox',
      'bridge',
      ...(registration ? ['synthetic'] : []),
    ]) {
      for (const name of fs.readdirSync(path.join(source, folder))) {
        fs.copyFileSync(
          path.join(source, folder, name),
          path.join(destination, name),
        );
        const relative = `PrivateInbox/${name}`;
        if (!project.hasFile(relative)) {
          project.addSourceFile(
            relative,
            { target },
            project.getFirstProject().firstProject.mainGroup,
          );
        }
      }
    }
    return result;
  });
};
