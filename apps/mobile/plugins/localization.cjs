const fs = require('node:fs');
const path = require('node:path');
const { scenario } = require('../../../scripts/mock-mail-build.cjs');
const {
  IOSConfig,
  withInfoPlist,
  withXcodeProject,
} = require('expo/config-plugins');

module.exports = function localization(config) {
  const localizedConfig = withInfoPlist(config, (result) => {
    result.modResults.CFBundleDevelopmentRegion = 'en';
    result.modResults.CFBundleLocalizations =
      require('../../../packages/localization/catalogs.bundle/languages.json').map(
        ({ code }) => code,
      );
    return result;
  });
  return withXcodeProject(localizedConfig, (result) => {
    const project = result.modResults;
    const target = project.getFirstTarget().uuid;
    const group = project.getFirstProject().firstProject.mainGroup;
    const root = result.modRequest.platformProjectRoot;
    const destination = path.join(root, 'Localization');
    fs.mkdirSync(destination, { recursive: true });
    const source = path.resolve(
      result.modRequest.projectRoot,
      '../../native/localization',
    );
    for (const name of [
      'UnwiredLocalization.m',
      'UnwiredLanguagePreferences.m',
      'UnwiredLanguagePreferences.h',
    ]) {
      fs.copyFileSync(path.join(source, name), path.join(destination, name));
      const relative = `Localization/${name}`;
      if (!project.hasFile(relative)) {
        if (name.endsWith('.h')) {
          project.addHeaderFile(relative, { target }, group);
        } else {
          project.addSourceFile(relative, { target }, group);
        }
      }
    }
    const localizationPackage = path.resolve(
      result.modRequest.projectRoot,
      '../../packages/localization',
    );
    const catalogs = path.join(root, 'catalogs.bundle');
    // Incremental prebuild of a production build removes what a Mock Mail Session build added.
    fs.rmSync(catalogs, { recursive: true, force: true });
    fs.cpSync(path.join(localizationPackage, 'catalogs.bundle'), catalogs, {
      recursive: true,
    });
    // Mock Mail Session builds also offer the German test catalog their JavaScript carries.
    if (scenario) {
      for (const name of ['de.json', 'languages.json']) {
        fs.copyFileSync(
          path.join(localizationPackage, 'src/testing', name),
          path.join(catalogs, name),
        );
      }
    }
    if (!project.hasFile('catalogs.bundle')) {
      IOSConfig.XcodeUtils.addResourceFileToGroup({
        filepath: 'catalogs.bundle',
        groupName: IOSConfig.XcodeUtils.getProjectName(
          result.modRequest.projectRoot,
        ),
        isBuildFile: true,
        project,
        targetUuid: target,
      });
    }
    return result;
  });
};
