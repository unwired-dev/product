const fs = require('node:fs');
const path = require('node:path');
const { withXcodeProject } = require('expo/config-plugins');

// Compiles the SF Symbol and Liquid Glass views the Mac host shares into the app target.
module.exports = function design(config) {
  return withXcodeProject(config, (result) => {
    const project = result.modResults;
    const destination = path.join(
      result.modRequest.platformProjectRoot,
      'Design',
    );
    fs.mkdirSync(destination, { recursive: true });
    for (const name of ['UnwiredDesign.m', 'UnwiredBackNavigation.m']) {
      fs.copyFileSync(
        path.resolve(
          result.modRequest.projectRoot,
          '../../native/design',
          name,
        ),
        path.join(destination, name),
      );
      const relative = `Design/${name}`;
      if (!project.hasFile(relative)) {
        project.addSourceFile(
          relative,
          { target: project.getFirstTarget().uuid },
          project.getFirstProject().firstProject.mainGroup,
        );
      }
    }
    return result;
  });
};
