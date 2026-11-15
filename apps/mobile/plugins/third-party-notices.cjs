const Schema = require('effect/Schema');
const { withXcodeProject } = require('expo/config-plugins');

module.exports = function thirdPartyNotices(config) {
  return withXcodeProject(config, (result) => {
    const phases =
      result.modResults.hash.project.objects.PBXShellScriptBuildPhase;
    const bundle = Object.values(phases).find(
      (phase) => phase?.name === '"Bundle React Native code and images"',
    );
    if (!bundle) {
      throw new Error('React Native bundle phase missing');
    }
    const marker = '# Unwired third-party notices';
    const script = Schema.decodeSync(Schema.fromJsonString(Schema.String))(
      bundle.shellScript,
    );
    // Prebuild can update an existing project. Keep one invocation and honour
    // TestFlight's external source-map destination when it supplies one.
    const original = script.split(marker)[0].trimEnd();
    const map = `export SOURCEMAP_FILE="\${SOURCEMAP_FILE:-$DERIVED_FILE_DIR/Unwired-main.jsbundle.map}"`;
    bundle.shellScript = JSON.stringify(
      [
        ...(original.includes(map) ? [] : [map]),
        original,
        marker,
        'unwired_bundle_status=$?',
        'if [ "$unwired_bundle_status" -ne 0 ]; then exit "$unwired_bundle_status"; fi',
        '/bin/sh "$SRCROOT/../../../scripts/bundle-third-party-notices.sh"',
      ].join('\n'),
    );
    return result;
  });
};
