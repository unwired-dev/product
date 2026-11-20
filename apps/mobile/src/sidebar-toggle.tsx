import type { SplitDisplayMode } from 'react-native-screens/experimental';

import { ipadListScale, radius } from '@private-email/mail-core/theme';
import { createContext, use, useMemo, useState } from 'react';
import { Pressable, StyleSheet } from 'react-native';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  toggle: {
    width: 32 * ipadListScale,
    height: 28 * ipadListScale,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control * ipadListScale,
  },
});

// Beside the list, the window's sidebar toggle: whether Mailboxes shows, and the way to change it.
// Without it, as when the split view collapses, UIKit's navigation bars carry the way back.
export const SidebarToggleContext = createContext<
  Readonly<{ shown: boolean; toggle: () => void }> | undefined
>(undefined);

// The sidebar toggle, at the trailing end of the sidebar's top row while it shows, or beside the
// list's command input while it hides.
export function SidebarToggle() {
  const sidebar = use(SidebarToggleContext);
  const colors = usePalette();
  const { t } = useLocalization();
  if (sidebar === undefined) {
    return null;
  }
  return (
    <Pressable
      accessibilityLabel={t(
        sidebar.shown ? 'native.hideSidebar' : 'native.showSidebar',
      )}
      accessibilityRole="button"
      hitSlop={6}
      onPress={() => {
        sidebar.toggle();
      }}
      style={({ pressed }) => [
        styles.toggle,
        pressed && { backgroundColor: colors.accentSelectionSubtle },
      ]}>
      <SFSymbol
        name="sidebar.leading"
        color={colors.textSecondary}
      />
    </Pressable>
  );
}

// Side by side, the columns draw their own headers, so the sidebar's toggle is ours: it asks UIKit
// for the display mode with or without Mailboxes beside the list, and follows each change UIKit
// makes, such as on rotation.
// Only a split view showing its columns side by side has the toggle.
export function useSidebarToggle(sideBySide: boolean, portrait: boolean) {
  const [displayMode, setDisplayMode] = useState<SplitDisplayMode>('automatic');
  const [shown, setShown] = useState(true);
  // UIKit ignores a display mode requested before it first places the columns, so the Portrait
  // one waits for its first report.
  const [placed, setPlaced] = useState(false);
  // A rotation returns to the new orientation's default, even after Show or Hide Sidebar (#2414).
  const [orientation, setOrientation] = useState(portrait);
  if (orientation !== portrait) {
    setOrientation(portrait);
    setDisplayMode('automatic');
  }
  const value = useMemo(
    () => ({
      shown,
      toggle: () => {
        setDisplayMode(shown ? 'oneBesideSecondary' : 'twoBesideSecondary');
      },
    }),
    [shown],
  );
  // The iPad Portrait frames hide Mailboxes and keep the list beside the reader, where UIKit
  // would show all three columns.
  const portraitDefault =
    displayMode === 'automatic' && sideBySide && portrait && placed;
  return {
    value: sideBySide ? value : undefined,
    displayMode: portraitDefault ? 'oneBesideSecondary' : displayMode,
    follow: (next: string) => {
      setPlaced(true);
      setShown(next.startsWith('two'));
      // Once the person has chosen a mode, by the toggle or by a swipe that leaves the Portrait
      // default, record the one UIKit reports, so the next toggle always asks for a change; until
      // then UIKit keeps choosing for the orientation.
      if (next === 'oneBesideSecondary' || next === 'twoBesideSecondary') {
        setDisplayMode((mode) =>
          mode === 'automatic' &&
          !(portraitDefault && next === 'twoBesideSecondary')
            ? mode
            : next,
        );
      }
    },
  };
}
