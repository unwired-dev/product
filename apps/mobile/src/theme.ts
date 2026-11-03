import {
  palette,
  profilePalette,
  typography,
} from '@private-email/mail-core/theme';
import { useColorScheme } from 'react-native';

export const textStyles = { ...typography.ios, reading: typography.reading };

// The current appearance, Light unless the system reports Dark.
export function useAppearance() {
  return useColorScheme() === 'dark' ? 'dark' : 'light';
}

export function usePalette() {
  return palette[useAppearance()];
}

// The Mail Profile Colors in the current appearance.
export function useProfilePalette() {
  return profilePalette[useAppearance()];
}
