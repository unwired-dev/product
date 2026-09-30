const fs = require('node:fs');
const path = require('node:path');
const { withXcodeProject } = require('expo/config-plugins');

module.exports = function privateInbox(config) {
  return withXcodeProject(config, (result) => {
    const project = result.modResults;
    const target = project.getFirstTarget().uuid;
    const root = result.modRequest.platformProjectRoot;
    const destination = path.join(root, 'PrivateInbox');
    fs.mkdirSync(destination, { recursive: true });
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
