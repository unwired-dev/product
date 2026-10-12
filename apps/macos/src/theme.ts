import { palette, typography } from '@private-email/mail-core/theme';
import { useColorScheme } from 'react-native';

export const textStyles = { ...typography.macos, reading: typography.reading };

export function usePalette() {
  return palette[useColorScheme() === 'dark' ? 'dark' : 'light'];
}
