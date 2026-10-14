import type { ReactNode } from 'react';

import { inboxCommands } from '@private-email/mail-core/commands';
import { View } from 'react-native';

import { CommandBar, RegisterCommands } from './command-palette.tsx';
import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';

// The account page of a connected Inbox keeps the window's Command Palette bar, and the palette
// offers the way back to the Inbox.
export function AccountPage({
  onInbox,
  children,
}: {
  readonly onInbox: () => void;
  readonly children: ReactNode;
}) {
  const { t } = useLocalization();
  return (
    <View style={styles.page}>
      <RegisterCommands offer={() => inboxCommands(t, { inbox: onInbox })} />
      <CommandBar />
      {children}
    </View>
  );
}
