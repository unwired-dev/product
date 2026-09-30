const path = require('node:path');

const scenario = process.env.UNWIRED_MOCK_SCENARIO;
if (
  scenario &&
  ![
    'open-read-relaunch',
    'mail-unavailable',
    'registration-cancelled',
    'registration-declined',
    'registration-no-gmail',
    'registration-interrupted',
  ].includes(scenario)
) {
  throw new Error('Unknown Mock Mail Session scenario');
}

module.exports = {
  scenario,
  resolveSeed(context, moduleName, platform) {
    if (
      moduleName === '@private-email/mail-core/registration-mode' &&
      scenario
    ) {
      return {
        type: 'sourceFile',
        filePath: path.resolve(
          __dirname,
          scenario.startsWith('registration-')
            ? '../packages/mail-core/src/testing/registration-onboarding.ts'
            : '../packages/mail-core/src/testing/registration-mode.ts',
        ),
      };
    }
    if (
      moduleName === '@private-email/mail-core/inbox-seed' &&
      scenario &&
      !scenario.startsWith('registration-')
    ) {
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
