import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import { profileMailboxes } from '@private-email/mail-core/mailboxes';
import { radius, spacing } from '@private-email/mail-core/theme';
import { Fragment, use } from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { InboxMailbox } from './private-storage.ts';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  useLeaveComposer,
  useMailboxes,
  useProfile,
  useReloadMailboxes,
} from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

// What the message list shows: every mailbox of the Profile, one mailbox, or one of its IMAP
// folders. The Inbox folder is the default of a mailbox.
export type MailboxView = Readonly<{
  mailbox?: string | undefined;
  folder?: string | undefined;
}>;

const compact = Platform.OS === 'ios' && !Platform.isPad;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  heading: { paddingHorizontal: spacing.xl, paddingVertical: spacing.l },
  title: { ...textStyles.headline, textAlign: 'center' },
  list: { paddingHorizontal: spacing.s, paddingBottom: spacing.l },
  compactList: { paddingHorizontal: spacing.l },
  group: {
    borderRadius: radius.mailboxGroup,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  compactSection: {
    ...textStyles.headline,
    paddingHorizontal: spacing.xs,
    paddingBottom: spacing.s,
  },
  compactRow: { minHeight: 52, paddingHorizontal: spacing.l, borderRadius: 0 },
  separator: { height: StyleSheet.hairlineWidth, marginHorizontal: spacing.l },
  section: {
    ...textStyles.footnote,
    fontWeight: '600',
    paddingHorizontal: spacing.s,
    paddingTop: spacing.l,
    paddingBottom: spacing.xs,
  },
  row: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.s,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.body, flex: 1 },
  count: { ...textStyles.subheadline },
  footer: { paddingHorizontal: spacing.s, paddingVertical: spacing.s },
});

const unreadCount = (mailbox: InboxMailbox) =>
  'messages' in mailbox.state && Array.isArray(mailbox.state.messages)
    ? mailbox.state.messages.filter(
        (message: Readonly<{ unread?: boolean }>) => message.unread === true,
      ).length
    : 0;

// A sidebar item: tinted symbol, label and unread count; selection shows as fill and weight.
function Item({
  icon,
  label,
  accessibilityLabel = label,
  count = 0,
  status,
  selected = false,
  onPress,
}: {
  readonly icon: string;
  readonly label: string;
  readonly accessibilityLabel?: string;
  readonly count?: number;
  // A problem beside the mailbox, in place of its count.
  readonly status?: string;
  readonly selected?: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const value =
    status ?? (count === 0 ? undefined : t('mailboxes.unread', { count }));
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      accessibilityValue={value === undefined ? undefined : { text: value }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        compact && styles.compactRow,
        (selected || pressed) && {
          backgroundColor: colors.accentSelectionSubtle,
        },
      ]}>
      <SFSymbol
        name={icon}
        color={colors.accentInk}
      />
      <Text
        numberOfLines={1}
        style={[
          styles.label,
          selected && { fontWeight: '600' },
          { color: colors.textPrimary },
        ]}>
        {label}
      </Text>
      {status === undefined ? null : (
        <SFSymbol
          name="exclamationmark.triangle"
          color={colors.statusWarning}
        />
      )}
      {count === 0 || status !== undefined ? null : (
        <Text style={[styles.count, { color: colors.textSecondary }]}>
          {count}
        </Text>
      )}
      {compact ? (
        <SFSymbol
          name="chevron.right"
          color={colors.textSecondary}
          size={12}
        />
      ) : null}
    </Pressable>
  );
}

function SectionHeader({ label }: { readonly label: string }) {
  const colors = usePalette();
  return (
    <Text
      accessibilityRole="header"
      numberOfLines={1}
      style={[
        styles.section,
        compact && styles.compactSection,
        { color: compact ? colors.textPrimary : colors.textSecondary },
      ]}>
      {label}
    </Text>
  );
}

// The Mailboxes of the window's Profile: every Inbox together, then each Mailbox Connection with
// its folders, and the account page last.
export function Mailboxes({
  view,
  onView,
}: {
  readonly view: MailboxView;
  readonly onView: (view: MailboxView) => void;
}) {
  const mailboxes = useMailboxes();
  const account = use(AccountContext);
  const profile = useProfile();
  const reload = useReloadMailboxes();
  const leave = useLeaveComposer();
  const colors = usePalette();
  const { t } = useLocalization();
  const chosen = mailboxes.find(({ id }) => id === view.mailbox);
  // Connections waiting for provider authorization have no Inbox until it is given again; they
  // stay listed with the problem beside them.
  const waiting = profileMailboxes(account?.mailboxes ?? [], profile).filter(
    ({ id, state }) =>
      state === 'authorization' &&
      !mailboxes.some((mailbox) => mailbox.id === id),
  );
  // The account page replaces the Inbox, so an open composer is left first.
  const openAccount = async (open: () => void) => {
    if (await leave()) {
      open();
    }
  };
  const authorize = async (connection: string) => {
    await account?.authorizeMailbox(connection);
    await reload();
  };
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true }}
      style={[
        styles.fill,
        compact && { backgroundColor: colors.surfaceContent },
      ]}>
      <View style={styles.fill}>
        <View style={styles.heading}>
          <Text
            accessibilityRole="header"
            style={[styles.title, { color: colors.textPrimary }]}>
            {t('mailboxes.title')}
          </Text>
        </View>
        <ScrollView
          style={styles.fill}
          contentContainerStyle={[styles.list, compact && styles.compactList]}>
          <SectionHeader label={t('mailboxes.favorites')} />
          <View
            style={
              compact && [styles.group, { backgroundColor: colors.fillQuiet }]
            }>
            <Item
              icon="tray.2"
              label={t('inbox.allInboxes')}
              count={mailboxes.reduce(
                (sum, mailbox) => sum + unreadCount(mailbox),
                0,
              )}
              selected={chosen === undefined}
              onPress={() => {
                onView({});
              }}
            />
          </View>
          {mailboxes.map((mailbox) => {
            const name = mailbox.address ?? mailbox.id;
            const { state } = mailbox;
            // An IMAP mailbox lists its selectable folders, Inbox first; others have one Inbox.
            const folders =
              state.kind === 'ready' && 'folders' in state
                ? state.folders.filter(({ selectable }) => selectable)
                : [{ name: inboxFolder }];
            return (
              <Fragment key={mailbox.id}>
                <SectionHeader
                  label={`${t(`mailProviders.${mailbox.provider ?? 'gmail'}`)} · ${name}`}
                />
                <View
                  style={
                    compact && [
                      styles.group,
                      { backgroundColor: colors.fillQuiet },
                    ]
                  }>
                  {folders.map(({ name: folder }, index) => {
                    const inbox = folder === inboxFolder;
                    const label = inbox ? t('inbox.title') : folder;
                    return (
                      <Fragment key={folder}>
                        {compact && index > 0 ? (
                          <View
                            style={[
                              styles.separator,
                              { backgroundColor: colors.separator },
                            ]}
                          />
                        ) : null}
                        <Item
                          icon={inbox ? 'tray' : 'folder'}
                          label={label}
                          accessibilityLabel={t('inbox.rowLabel_mailbox', {
                            row: label,
                            mailbox: name,
                          })}
                          count={inbox ? unreadCount(mailbox) : 0}
                          selected={
                            chosen === mailbox &&
                            (view.folder ?? inboxFolder) === folder
                          }
                          onPress={() => {
                            onView({
                              mailbox: mailbox.id,
                              folder: inbox ? undefined : folder,
                            });
                            if ('openFolder' in mailbox.inbox) {
                              void mailbox.inbox.openFolder(folder);
                            }
                          }}
                        />
                      </Fragment>
                    );
                  })}
                </View>
              </Fragment>
            );
          })}
          {waiting.map((connection) => {
            const provider = t(`mailProviders.${connection.provider}`);
            const imap = connection.provider === 'imap';
            return (
              <Fragment key={connection.id}>
                <SectionHeader label={`${provider} · ${connection.address}`} />
                <View
                  style={
                    compact && [
                      styles.group,
                      { backgroundColor: colors.fillQuiet },
                    ]
                  }>
                  <Item
                    icon="tray"
                    label={t('inbox.title')}
                    accessibilityLabel={t('inbox.rowLabel_mailbox', {
                      row: t('inbox.title'),
                      mailbox: connection.address,
                    })}
                    status={
                      imap
                        ? t('mailboxes.states.imap-authorization')
                        : t('mailboxes.states.authorization', { provider })
                    }
                    onPress={() => {
                      // IMAP needs its password entered again on the account page.
                      if (imap) {
                        if (account !== undefined) {
                          void openAccount(account.openAccount);
                        }
                      } else {
                        void authorize(connection.id);
                      }
                    }}
                  />
                </View>
              </Fragment>
            );
          })}
        </ScrollView>
        {account === undefined ? null : (
          <View style={styles.footer}>
            <Item
              icon="gearshape"
              label={t('inbox.account')}
              onPress={() => {
                void openAccount(account.openAccount);
              }}
            />
          </View>
        )}
      </View>
    </SafeAreaView>
  );
}
