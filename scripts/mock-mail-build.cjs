const path = require('node:path');

const Schema = require('effect/Schema');

const { buildPage } = require('../packages/draft-editor/build.cjs');

const { build } = Schema.decodeSync(
  Schema.Struct({ build: Schema.Array(Schema.NonEmptyString) }),
)(require('./mock-mail-scenarios.json'));

const scenario = process.env.UNWIRED_MOCK_SCENARIO;
if (scenario && !Schema.is(Schema.Literals(build))(scenario)) {
  throw new Error('Unknown Mock Mail Session scenario');
}

const testing = (source) =>
  path.resolve(__dirname, `../packages/mail-core/src/testing/${source}.ts`);
// Registration scenarios substitute a native provider only; their JavaScript stays production
// apart from the evaluation editor page.
const seeded = scenario && !scenario.startsWith('registration-');
const substitutes = {
  ...(seeded && {
    '@private-email/mail-core/registration-mode': testing('registration-mode'),
    '@private-email/mail-core/inbox-seed': testing(scenario),
  }),
  // Built before Metro crawls, so the substitute exists in its file map.
  ...(scenario === 'registration-draft-editor' && {
    '@private-email/draft-editor/page': buildPage(),
  }),
};

module.exports = {
  scenario,
  resolveSeed(context, moduleName, platform) {
    const filePath = substitutes[moduleName];
    return filePath
      ? { type: 'sourceFile', filePath }
      : context.resolveRequest(context, moduleName, platform);
  },
};
