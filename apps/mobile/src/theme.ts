import {
  palette,
  profilePalette,
  typography,
} from '@private-email/mail-core/theme';
import { useColorScheme, useWindowDimensions } from 'react-native';

export const textStyles = { ...typography.ios, reading: typography.reading };

// Whether the system text size is one of the accessibility sizes, where single lines would cut text
// short: rows wrap and side-by-side text stacks.
export function useLargeText() {
  return useWindowDimensions().fontScale > 1.4;
}

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
