import { env } from 'node:process';

import type { ExpoConfig } from 'expo/config';

import scenarios from '../../scripts/mock-mail-scenarios.json';

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

const config: ExpoConfig = {
  name: 'Unwired Mail Preview',
  slug: 'unwired-mail-preview',
  scheme: googleClientID
    ? ['unwired-mail-preview', googleScheme]
    : 'unwired-mail-preview',
  version: '0.1.0',
  platforms: ['ios'],
  userInterfaceStyle: 'automatic',
  ios: {
    bundleIdentifier: 'dev.unwired.mail.preview',
    supportsTablet: true,
    infoPlist: {
      ...(mockScenario ? { UnwiredMockScenario: mockScenario } : {}),
      GIDClientID: googleClientID,
      UnwiredConvexURL: convexURL,
    },
  },
  plugins: [
    'expo-router',
    './plugins/private-inbox.cjs',
    [
      'expo-build-properties',
      { ios: { deploymentTarget: '27.0', enableSceneSupport: true } },
    ],
  ],
};

export default config;
