import { env } from 'node:process';

import type { ExpoConfig } from 'expo/config';

import * as Schema from 'effect/Schema';

import scenarios from '../../scripts/mock-mail-scenarios.json';
import manifest from './package.json';

const { build } = Schema.decodeSync(
  Schema.Struct({ build: Schema.Array(Schema.NonEmptyString) }),
)(scenarios);
const mockScenario: unknown = env.UNWIRED_MOCK_SCENARIO;
if (
  mockScenario !== undefined &&
  mockScenario !== '' &&
  !Schema.is(Schema.Literals(build))(mockScenario)
) {
  throw new Error('Unknown Mock Mail Session scenario');
}

const googleClientID: unknown = env.UNWIRED_GOOGLE_CLIENT_ID ?? '';
const microsoftClientID: unknown = env.UNWIRED_MICROSOFT_CLIENT_ID ?? '';
const convexURL: unknown = env.UNWIRED_CONVEX_URL ?? '';
// The Cloud Pub/Sub topic Gmail watches publish to; without one no push route is registered.
const gmailTopic: unknown = env.UNWIRED_GMAIL_PUBSUB_TOPIC ?? '';
if (
  !Schema.is(Schema.String)(googleClientID) ||
  !Schema.is(Schema.String)(microsoftClientID) ||
  !Schema.is(Schema.String)(convexURL) ||
  !Schema.is(Schema.String)(gmailTopic)
) {
  throw new TypeError('Invalid native registration configuration');
}
// The public-client application ID; without it, Microsoft mail cannot be connected.
if (
  microsoftClientID &&
  !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/iu.test(microsoftClientID)
) {
  throw new Error('Invalid Microsoft application client ID');
}
const googleScheme = googleClientID.split('.').toReversed().join('.');
if (
  googleClientID &&
  !/^[0-9A-Za-z-]+\.apps\.googleusercontent\.com$/u.test(googleClientID)
) {
  throw new Error('Invalid native Google OAuth client ID');
}

// Release uploads stamp their UTC build number and source commit.
const buildNumber: unknown = env.UNWIRED_BUILD_NUMBER ?? '1';
const commit: unknown = env.UNWIRED_COMMIT ?? '';
// The signing team; without it, Expo asks which keychain identity signs local builds.
const team: unknown = env.UNWIRED_DEVELOPMENT_TEAM ?? '';
if (
  !Schema.is(Schema.String.check(Schema.isPattern(/^[0-9]+$/u)))(buildNumber) ||
  !Schema.is(Schema.String)(commit) ||
  !Schema.is(Schema.String.check(Schema.isPattern(/^(?:[0-9A-Za-z]{10})?$/u)))(
    team,
  )
) {
  throw new TypeError('Invalid release build configuration');
}

const reportingQualification =
  env.UNWIRED_ERROR_REPORTING_QUALIFICATION === '1';
const nativeReportingQualified =
  env.UNWIRED_NATIVE_ERROR_REPORTING_QUALIFIED === '1';
const reportingChannel: unknown =
  env.UNWIRED_ERROR_REPORTING_CHANNEL ??
  (reportingQualification ? 'qualification' : 'production');
if (
  !Schema.is(Schema.Literals(['production', 'testflight', 'qualification']))(
    reportingChannel,
  )
) {
  throw new TypeError('Invalid error reporting channel');
}

const config: ExpoConfig = {
  name: 'Unwired Mail',
  slug: 'unwired-mail',
  scheme: googleClientID ? ['unwired-mail', googleScheme] : 'unwired-mail',
  version: manifest.version,
  platforms: ['ios'],
  userInterfaceStyle: 'automatic',
  ios: {
    bundleIdentifier: 'dev.unwired.mail',
    buildNumber,
    ...(team ? { appleTeamId: team } : {}),
    icon: '../../native/app-icon/UnwiredMail.icon',
    supportsTablet: true,
    // Only Apple's system cryptography and HTTPS are used.
    config: { usesNonExemptEncryption: false },
    // Native Sign in with Apple and content-free Gmail wakes; declared directly because no Expo
    // module supplies them. Distribution signing replaces the APNs environment with production.
    entitlements: {
      'com.apple.developer.applesignin': ['Default'],
      'aps-environment': 'development',
    },
    infoPlist: {
      ...(mockScenario ? { UnwiredMockScenario: mockScenario } : {}),
      GIDClientID: googleClientID,
      UnwiredMicrosoftClientID: microsoftClientID.toLowerCase(),
      UnwiredConvexURL: convexURL,
      UnwiredErrorReportingQualification: reportingQualification,
      UnwiredNativeErrorReportingQualified: nativeReportingQualified,
      UnwiredErrorReportingChannel: reportingChannel,
      ...(gmailTopic ? { UnwiredGmailTopic: gmailTopic } : {}),
      UIBackgroundModes: ['remote-notification'],
      ...(commit ? { UnwiredCommit: commit } : {}),
    },
  },
  plugins: [
    'expo-router',
    './plugins/private-inbox.cjs',
    './plugins/localization.cjs',
    './plugins/design.cjs',
    'expo-background-task',
    [
      'expo-build-properties',
      { ios: { deploymentTarget: '27.0', enableSceneSupport: true } },
    ],
  ],
};

export default config;
