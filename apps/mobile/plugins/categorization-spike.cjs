const fs = require('node:fs');
const path = require('node:path');
const { scenario } = require('../../../scripts/mock-mail-build.cjs');
const { withXcodeProject } = require('expo/config-plugins');

const phaseName = 'Bundle categorization spike';

// Spike #830: only its Mock Mail Session build compiles the Core ML runner and bundles the models.
// Incremental prebuild of any other scenario removes what an earlier spike build added.
module.exports = function categorizationSpike(config) {
  return withXcodeProject(config, (result) => {
    const project = result.modResults;
    const target = project.getFirstTarget().uuid;
    const group = project.getFirstProject().firstProject.mainGroup;
    const root = result.modRequest.platformProjectRoot;
    const source = path.resolve(
      result.modRequest.projectRoot,
      '../../native/categorization-spike',
    );
    const spike = scenario === 'categorization-spike';
    const folders = ['Sources/CategorizationSpike', 'bridge'];
    fs.mkdirSync(path.join(root, 'CategorizationSpike'), { recursive: true });
    for (const folder of folders) {
      for (const name of fs.readdirSync(path.join(source, folder))) {
        const relative = `CategorizationSpike/${name}`;
        if (spike) {
          fs.copyFileSync(
            path.join(source, folder, name),
            path.join(root, relative),
          );
          if (!project.hasFile(relative)) {
            project.addSourceFile(relative, { target }, group);
          }
        } else {
          if (project.hasFile(relative)) {
            project.removeSourceFile(relative, { target }, group);
          }
          fs.rmSync(path.join(root, relative), { force: true });
        }
      }
    }
    const phases = project.hash.project.objects.PBXShellScriptBuildPhase ?? {};
    const existing = Object.entries(phases).find(
      ([, phase]) => phase?.name === `"${phaseName}"`,
    );
    const shellScript = [
      'set -e',
      'spike="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/CategorizationSpike"',
      ...(spike
        ? [
            'mkdir -p "$spike"',
            'benchmark="$SRCROOT/../../../tools/system-category-benchmark/custom"',
            'cp "$benchmark/golden-v1.json" "$benchmark/categories-v1.json" "$spike/"',
            '# Exported by tools/deberta-mac-spike/export.py; without them the page reports the models unavailable.',
            'models="$SRCROOT/../../../tools/deberta-mac-spike/work/models"',
            'if [ -d "$models" ]; then rsync -a --delete --exclude \'*.mlpackage\' "$models/" "$spike/models/"; else rm -rf "$spike/models"; fi',
          ]
        : ['rm -rf "$spike"']),
    ].join('\n');
    if (existing === undefined) {
      project.addBuildPhase([], 'PBXShellScriptBuildPhase', phaseName, target, {
        shellPath: '/bin/sh',
        alwaysOutOfDate: 1,
        shellScript,
      });
    } else {
      // Xcode retains script-created resources on an incremental build. Other scenarios must
      // actively remove the prior spike's models, not just remove its copy phase.
      existing[1].shellScript = JSON.stringify(shellScript);
    }
    return result;
  });
};
