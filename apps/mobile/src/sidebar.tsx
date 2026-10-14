import type { Translate } from '@private-email/localization';
import type { MailboxProblem } from '@private-email/mail-core/mailboxes';
import type { MailProvider } from '@private-email/mail-core/registration';

import {
  failedFolders,
  mailboxSidebar,
} from '@private-email/mail-core/mailboxes';
import { radius, spacing } from '@private-email/mail-core/theme';
import { Fragment, use, useSyncExternalStore } from 'react';
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

import { usePaletteHeader } from './command-palette.tsx';
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
  readonly status?: string | undefined;
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

// The problem beside a mailbox, in the words its Inbox notice uses.
const problemText = (
  t: Translate,
  problem: MailboxProblem | undefined,
  {
    provider,
    name,
  }: Readonly<{ provider: MailProvider | undefined; name: string }>,
) => {
  if (problem === undefined) {
    return undefined;
  }
  if (problem === 'locked' || problem === 'failed') {
    return t(`storage.${problem}`);
  }
  return provider === 'imap'
    ? t(`imapSync.${problem}`)
    : t(`gmailSync.${problem}`, { provider: name });
};

const noSubscription = () => () => undefined;

// A Mailbox Connection's folder rows. An IMAP folder whose last read failed keeps its warning
// after another mailbox is chosen; the connection's own problem rides on its Inbox row.
function FolderRows({
  mailbox,
  folders,
  trouble,
  onView,
}: {
  readonly mailbox: InboxMailbox;
  readonly folders: ReadonlyArray<
    Readonly<{
      name: string;
      inbox: boolean;
      unread: number;
      selected: boolean;
    }>
  >;
  readonly trouble: string | undefined;
  readonly onView: (view: MailboxView) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { inbox } = mailbox;
  const name = mailbox.address ?? mailbox.id;
  const names = folders.map((folder) => folder.name);
  // JSON strings escape folder-name newlines while keeping the joined snapshot stable.
  const failed = useSyncExternalStore(
    'openFolder' in inbox ? inbox.subscribe : noSubscription,
    () =>
      'openFolder' in inbox
        ? failedFolders(inbox, names)
            .map((folder) => JSON.stringify(folder))
            .join('\n')
        : '',
  ).split('\n');
  const folderTrouble = (folder: string) =>
    failed.includes(JSON.stringify(folder))
      ? t('imap.foldersUnavailable')
      : undefined;
  return (
    <View
      style={compact && [styles.group, { backgroundColor: colors.fillQuiet }]}>
      {folders.map(
        ({ name: folder, inbox: isInbox, unread, selected }, index) => {
          const label = isInbox ? t('inbox.title') : folder;
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
                icon={isInbox ? 'tray' : 'folder'}
                label={label}
                accessibilityLabel={t('inbox.rowLabel_mailbox', {
                  row: label,
                  mailbox: name,
                })}
                count={unread}
                status={isInbox ? trouble : folderTrouble(folder)}
                selected={selected}
                onPress={() => {
                  onView({
                    mailbox: mailbox.id,
                    folder: isInbox ? undefined : folder,
                  });
                  if ('openFolder' in inbox) {
                    void inbox.openFolder(folder);
                  }
                }}
              />
            </Fragment>
          );
        },
      )}
    </View>
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
  const header = usePaletteHeader();
  const sidebar = mailboxSidebar({
    mailboxes,
    connections: account?.mailboxes ?? [],
    profile,
    view,
  });
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
        {/* The header opens the Command Palette by a downward swipe or its accessibility action. */}
        <View
          style={styles.heading}
          {...header.swipe}>
          <Text
            accessibilityRole="header"
            style={[styles.title, { color: colors.textPrimary }]}
            {...header.action}>
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
              count={sidebar.unread}
              selected={sidebar.allSelected}
              onPress={() => {
                onView({});
              }}
            />
          </View>
          {sidebar.entries.map((entry) => {
            if ('section' in entry) {
              const { mailbox, folders, problem } = entry.section;
              const name = mailbox.address ?? mailbox.id;
              const provider = t(
                `mailProviders.${mailbox.provider ?? 'gmail'}`,
              );
              const trouble = problemText(t, problem, {
                provider: mailbox.provider,
                name: provider,
              });
              return (
                <Fragment key={mailbox.id}>
                  <SectionHeader label={`${provider} · ${name}`} />
                  <FolderRows
                    mailbox={mailbox}
                    folders={folders}
                    trouble={trouble}
                    onView={onView}
                  />
                </Fragment>
              );
            }
            const { connection, recovery, selected } = entry.waiting;
            const provider = t(`mailProviders.${connection.provider}`);
            const imap = recovery === 'account';
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
                    selected={selected}
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
