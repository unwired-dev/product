import {
  palette,
  profilePalette,
  typography,
} from '@private-email/mail-core/theme';
import { useColorScheme } from 'react-native';

export const textStyles = { ...typography.macos, reading: typography.reading };

export function usePalette() {
  return palette[useColorScheme() === 'dark' ? 'dark' : 'light'];
}

// The Mail Profile Colors in the current appearance.
export function useProfilePalette() {
  return profilePalette[useColorScheme() === 'dark' ? 'dark' : 'light'];
}
