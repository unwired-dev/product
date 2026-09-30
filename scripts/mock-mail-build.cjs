const path = require('node:path');

const scenario = process.env.UNWIRED_MOCK_SCENARIO;
if (
  scenario &&
  !['open-read-relaunch', 'mail-unavailable'].includes(scenario)
) {
  throw new Error('Unknown Mock Mail Session scenario');
}

module.exports = {
  scenario,
  resolveSeed(context, moduleName, platform) {
    if (moduleName === '@private-email/mail-core/inbox-seed' && scenario) {
      return {
        type: 'sourceFile',
        filePath: path.resolve(
          __dirname,
          `../packages/mail-core/src/testing/${scenario}.ts`,
        ),
      };
    }
    return context.resolveRequest(context, moduleName, platform);
  },
};
