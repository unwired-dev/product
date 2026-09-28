import { palette } from '@private-email/mail-core/theme';
import { useColorScheme } from 'react-native';

export function usePalette() {
  return palette[useColorScheme() === 'dark' ? 'dark' : 'light'];
}
