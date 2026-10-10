const fs = require('node:fs');
const path = require('node:path');
const { scenario } = require('../../../scripts/mock-mail-build.cjs');
const {
  withXcodeProject,
  withPodfile,
  withAppDelegate,
} = require('expo/config-plugins');

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
  const scenarioSetting = JSON.stringify(scenario ?? '');
  return withXcodeProject(withGoogleCallback, (result) => {
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
    // Incremental prebuild keeps files and references copied before this fixture moved to tests.
    const retired = 'PrivateInbox/SyntheticCredential.swift';
    if (project.hasFile(retired)) {
      project.removeSourceFile(
        retired,
        { target },
        project.getFirstProject().firstProject.mainGroup,
      );
    }
    fs.rmSync(path.join(root, retired), { force: true });
    const source = path.resolve(
      result.modRequest.projectRoot,
      '../../native/private-inbox',
    );
    for (const folder of ['Sources/PrivateInbox', 'bridge']) {
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
