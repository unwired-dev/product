import { env } from 'node:process';

import type { ExpoConfig } from 'expo/config';

import * as Schema from 'effect/Schema';

import scenarios from '../../scripts/mock-mail-scenarios.json';
import manifest from './package.json';

const mockScenario: unknown = env.UNWIRED_MOCK_SCENARIO;
if (
  mockScenario !== undefined &&
  mockScenario !== '' &&
  (typeof mockScenario !== 'string' || !scenarios.build.includes(mockScenario))
) {
  throw new Error('Unknown Mock Mail Session scenario');
}

const googleClientID: unknown = env.UNWIRED_GOOGLE_CLIENT_ID ?? '';
const convexURL: unknown = env.UNWIRED_CONVEX_URL ?? '';
if (typeof googleClientID !== 'string' || typeof convexURL !== 'string') {
  throw new TypeError('Invalid native registration configuration');
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
if (
  !Schema.is(Schema.String.check(Schema.isPattern(/^[0-9]+$/u)))(buildNumber) ||
  !Schema.is(Schema.String)(commit)
) {
  throw new TypeError('Invalid release build configuration');
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
    icon: '../../native/app-icon/UnwiredMail.icon',
    supportsTablet: true,
    // Only Apple's system cryptography and HTTPS are used.
    config: { usesNonExemptEncryption: false },
    // Native Sign in with Apple; declared directly because no Expo module supplies it.
    entitlements: { 'com.apple.developer.applesignin': ['Default'] },
    infoPlist: {
      ...(mockScenario ? { UnwiredMockScenario: mockScenario } : {}),
      GIDClientID: googleClientID,
      UnwiredConvexURL: convexURL,
      ...(commit ? { UnwiredCommit: commit } : {}),
    },
  },
  plugins: [
    'expo-router',
    './plugins/private-inbox.cjs',
    './plugins/localization.cjs',
    [
      'expo-build-properties',
      { ios: { deploymentTarget: '27.0', enableSceneSupport: true } },
    ],
  ],
};

export default config;
