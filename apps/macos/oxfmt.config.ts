import { extendOxfmtConfig } from '@rajzik/oxfmt-config';

export default extendOxfmtConfig({
  ignorePatterns: ['macos/**', 'dist/**', 'expo-env.d.ts'],
});
