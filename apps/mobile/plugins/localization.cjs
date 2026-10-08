const fs = require('node:fs');
const path = require('node:path');
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
    fs.cpSync(
      path.resolve(
        result.modRequest.projectRoot,
        '../../packages/localization/catalogs.bundle',
      ),
      path.join(root, 'catalogs.bundle'),
      { recursive: true },
    );
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
