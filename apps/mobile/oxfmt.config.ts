import { extendOxfmtConfig } from '@rajzik/oxfmt-config';

export default extendOxfmtConfig({
  ignorePatterns: ['ios/**', '.expo/**', 'dist/**', 'expo-env.d.ts'],
});
