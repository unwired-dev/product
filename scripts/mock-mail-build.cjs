const path = require('node:path');

const scenarios = require('./mock-mail-scenarios.json');

const scenario = process.env.UNWIRED_MOCK_SCENARIO;
if (scenario && !scenarios.build.includes(scenario)) {
  throw new Error('Unknown Mock Mail Session scenario');
}

module.exports = {
  scenario,
  resolveSeed(context, moduleName, platform) {
    // Registration scenarios substitute a native provider only; their JavaScript stays production.
    const seeded = scenario && !scenario.startsWith('registration-');
    const source =
      seeded &&
      {
        '@private-email/mail-core/registration-mode': 'registration-mode',
        '@private-email/mail-core/inbox-seed': scenario,
      }[moduleName];
    if (!source) {
      return context.resolveRequest(context, moduleName, platform);
    }
    return {
      type: 'sourceFile',
      filePath: path.resolve(
        __dirname,
        `../packages/mail-core/src/testing/${source}.ts`,
      ),
    };
  },
};
