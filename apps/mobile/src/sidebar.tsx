import type { Translate } from '@private-email/localization';
import type {
  Favorite,
  FavoriteEntries,
  MailboxProblem,
  SectionFolders,
  UnifiedRole,
} from '@private-email/mail-core/mailboxes';
import type {
  MailboxConnection,
  MailProvider,
} from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';
import type { LayoutChangeEvent, ScrollViewInstance } from 'react-native';

import { Host, Button as SwiftUIButton } from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  controlSize,
  disabled,
  labelStyle,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { sidebarCommands } from '@private-email/mail-core/commands';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  allInboxes,
  failedFolders,
  favoriteRows,
  folderRows,
  gmailMailbox,
  gmailViewRow,
  mailboxSidebar,
  moveFavorite,
  moveFolder,
  profileMailboxes,
  sectionFolders,
  sectionShown,
  showFavorite,
  showFolder,
  unifiedRow,
} from '@private-email/mail-core/mailboxes';
import {
  profileMenu,
  profileName,
  profileStyle,
} from '@private-email/mail-core/profile-windows';
import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import {
  createContext,
  Fragment,
  use,
  useEffect,
  useEffectEvent,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  Alert,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { InboxMailbox } from './private-storage.ts';
import type { SettingsDestination } from './settings.tsx';

import { RegisterCommands, usePaletteHeader } from './command-palette.tsx';
import {
  GlassGroup,
  MenuButton,
  NavigationChrome,
  SFSymbol,
  SignInNotice,
} from './design.tsx';
import { BarSpacer, FloatingBar, NewMessageButton } from './inbox-bar.tsx';
import {
  InboxPreferencesContext,
  useReadSections,
  useSections,
} from './list-density.tsx';
import { useLocalization } from './localization.ts';
import { useAllMailboxes } from './mailbox-state.ts';
import { useMailboxes, useProfile, useReloadMailboxes } from './mailbox.tsx';
import { useProfileOutbox } from './outbox.tsx';
import { ProfileMonogram, promptNewProfile } from './profile-settings.tsx';
import { AccountContext } from './registration-gate.tsx';
import { SidebarToggle, SidebarToggleContext } from './sidebar-toggle.tsx';
import { limited } from './sync-status.tsx';
import {
  textStyles,
  useLargeText,
  usePalette,
  useProfilePalette,
} from './theme.ts';

// What the message list shows: every mailbox of the Profile, one mailbox, one of its folders, a
// Unified Mailbox of every mailbox, or the Profile's Outbox. The Inbox folder is the default of a
// mailbox.
export type MailboxView = Readonly<{
  mailbox?: string | undefined;
  folder?: string | undefined;
  unified?: UnifiedRole | undefined;
  outbox?: boolean | undefined;
}>;

const compact = Platform.OS === 'ios' && !Platform.isPad;

const sectionText = {
  ...typography.ipadList.subheadline,
  fontWeight: '600',
} as const;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  // iPhone's title sits centered between an empty slot and Account.
  compactHeading: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.xs,
  },
  // Edit, or Done, and Account share the trailing half of the header, so the title stays centered.
  headingActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
  },
  accountGlass: {
    padding: 0,
    borderRadius: 22,
    backgroundColor: 'transparent',
  },
  accountButton: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  // The frames set the title 12pt below the header's top, 3pt above its centre.
  title: { ...textStyles.headline, textAlign: 'center', paddingBottom: 6 },
  grow: { flex: 1 },
  list: { paddingBottom: spacing.l },
  // The last rows scroll clear of the floating New Message; the Profile Switcher sits 14pt below
  // the header.
  compactList: {
    paddingHorizontal: spacing.l,
    paddingTop: 14,
    paddingBottom: 72,
  },
  group: {
    borderRadius: radius.mailboxGroup,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  // The frames' 28pt section header with 10pt above and below it.
  compactSection: {
    ...textStyles.headline,
    paddingHorizontal: spacing.xs,
    paddingTop: spacing.l,
    paddingBottom: 10,
  },
  // The frames' header with a problem: the warning 6pt after the title, which truncates before it.
  compactSectionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: spacing.xs,
    paddingTop: spacing.l,
    paddingBottom: 10,
  },
  // The Authorization Needed banner sits 10pt above the connection's folders.
  compactNotice: { marginBottom: 10 },
  // Each symbol takes a 24pt slot, so the labels share the frames' x68 axis.
  compactRow: {
    minHeight: 52,
    gap: spacing.m,
    paddingHorizontal: spacing.l,
    borderRadius: 0,
  },
  compactIcon: { width: 24, alignItems: 'center' },
  separator: { height: StyleSheet.hairlineWidth, marginHorizontal: spacing.l },
  // In Edit mode iPhone's hairlines start at the label, 90pt in, and run to the group's edge.
  editSeparator: { marginLeft: 90, marginRight: 0 },
  // The iPad sidebar follows the Mac recipe at 1.15×, as its frames draw it.
  section: {
    ...sectionText,
    paddingHorizontal: spacing.s * ipadListScale,
    paddingTop: spacing.m * ipadListScale,
    paddingBottom: spacing.xs * ipadListScale,
  },
  // A Mailbox Connection's header with its problem: the title truncates before the warning.
  sectionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs * ipadListScale,
    paddingHorizontal: spacing.s * ipadListScale,
    paddingTop: spacing.m * ipadListScale,
    paddingBottom: spacing.xs * ipadListScale,
  },
  sectionTitle: { ...sectionText, flexShrink: 1 },
  // iPhone's title fills the header, so the warning keeps to its trailing end.
  compactSectionTitle: { ...textStyles.headline, flex: 1 },
  row: {
    minHeight: 28 * ipadListScale,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s * ipadListScale,
    paddingHorizontal: spacing.s * ipadListScale,
    borderRadius: radius.control * ipadListScale,
    borderCurve: 'continuous',
  },
  // An Edit row: checkmark, symbol, name and drag handle, 8pt apart in their slots.
  editRow: { gap: spacing.s },
  // A Mailbox Connection's header in Edit mode keeps its header's spacing above it.
  editHeader: { marginTop: spacing.m * ipadListScale - spacing.xs },
  compactEditHeader: {
    minHeight: 44,
    paddingLeft: spacing.xs,
    paddingRight: 18,
    marginTop: spacing.l - 10,
  },
  // iPhone's 52pt Edit row: its 26pt slots 12pt apart, 14pt from the group's leading edge and 18pt
  // from its trailing one.
  compactEditRow: {
    minHeight: 52,
    gap: spacing.m,
    paddingLeft: 14,
    paddingRight: 18,
    borderRadius: 0,
  },
  checkSlot: { width: 18, alignItems: 'center' },
  editIcon: { width: 20, alignItems: 'center' },
  compactSlot: { width: 26, alignItems: 'center' },
  handle: { alignSelf: 'stretch', justifyContent: 'center' },
  label: { ...typography.ipadList.body, flex: 1 },
  compactLabel: { ...textStyles.body, flex: 1 },
  compactCount: { ...textStyles.subheadline },
  count: { ...typography.ipadList.body },
  // As the frames draw it, Settings sits 6.9pt beneath their 1.15pt rule and 11.2pt above the
  // panel's edge.
  footer: {
    paddingTop: 6 * ipadListScale,
    paddingBottom: 11.2,
    borderTopWidth: ipadListScale,
  },
  switcher: {
    minHeight: 28 * ipadListScale,
    marginBottom: spacing.xs * ipadListScale,
    borderRadius: radius.control * ipadListScale,
    borderCurve: 'continuous',
  },
  // The floating sidebar panel, inset 8pt from the column beneath the status bar and from the
  // window's bottom edge, as the frames draw it from y40 to y826: 271.4pt wide in the 286pt column,
  // its rows and footer 9.2pt inside it.
  panel: {
    flex: 1,
    margin: spacing.s,
    marginRight: 286 - spacing.s - 271.4,
    paddingHorizontal: spacing.s * ipadListScale,
    borderRadius: radius.window * ipadListScale,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
    overflow: 'hidden',
  },
  // The window controls' row of the panel: its sidebar toggle at the trailing end, 11.8pt below the
  // panel's top edge on the top row's centre line, and the Profile Switcher 57.5pt below it.
  panelTop: {
    height: 57.5,
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'flex-end',
    gap: 9,
    paddingTop: 11.8,
  },
  // Edit and Done keep the toggle's 32.2pt height, centered on its row.
  panelButton: { height: 28 * ipadListScale, justifyContent: 'center' },
  compactSwitcher: {
    minHeight: 48,
    marginBottom: spacing.s,
    borderRadius: radius.profileSwitcher,
  },
  switcherRow: {
    flexGrow: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.s,
  },
  // iPhone fills the row itself, since the native menu host's fill would draw twice, 12pt in with
  // 12pt beside its monogram.
  compactSwitcherRow: {
    minHeight: 48,
    gap: spacing.m,
    paddingHorizontal: spacing.m,
    borderRadius: radius.profileSwitcher,
    borderCurve: 'continuous',
  },
  switcherName: { ...typography.ipadList.body, fontWeight: '600', flex: 1 },
  compactSwitcherName: { ...textStyles.headline, flex: 1 },
});

// The window's Profile Switcher: its Mail Profile's monogram, name and chevron. Its system menu
// switches this window's Profile or names a new one.
function ProfileSwitcher({
  onProfile,
  onManage,
}: {
  readonly onProfile: (profile: string) => void;
  // Opens Settings on Mail Profiles.
  readonly onManage: () => void;
}) {
  const account = use(AccountContext);
  const profile = useProfile();
  const mailboxes = useAllMailboxes();
  const colors = usePalette();
  const fills = useProfilePalette();
  const { t } = useLocalization();
  if (account === undefined) {
    return null;
  }
  const { profiles } = account;
  const name = profileName(t, profile, profiles);
  return (
    <MenuButton
      accessibilityLabel={t('profiles.switcher', { name })}
      sections={profileMenu(t, {
        profiles,
        connections: account.mailboxes,
        mailboxes,
        current: profile,
        onSwitch: onProfile,
        onCreate: () => {
          promptNewProfile(t, account.createProfile);
        },
        onManage,
        fills,
      })}
      style={[
        styles.switcher,
        compact
          ? styles.compactSwitcher
          : { backgroundColor: colors.fillQuiet },
      ]}>
      <View
        style={[
          styles.switcherRow,
          compact && [
            styles.compactSwitcherRow,
            { backgroundColor: colors.fillQuiet },
          ],
        ]}>
        <ProfileMonogram
          name={name}
          style={profileStyle(profiles, profile)}
          size={28}
        />
        <Text
          numberOfLines={1}
          style={[
            compact ? styles.compactSwitcherName : styles.switcherName,
            { color: colors.textPrimary },
          ]}>
          {name}
        </Text>
        <SFSymbol
          name="chevron.down"
          color={colors.textSecondary}
          size={12}
        />
      </View>
    </MenuButton>
  );
}

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
  // At accessibility text sizes labels wrap, as UIKit's sidebar lists do.
  const large = useLargeText();
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
      <View style={compact && styles.compactIcon}>
        <SFSymbol
          name={icon}
          color={colors.accentInk}
        />
      </View>
      <Text
        numberOfLines={large ? 0 : 1}
        style={[
          compact ? styles.compactLabel : styles.label,
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
        <Text
          style={[
            compact ? styles.compactCount : styles.count,
            { color: colors.textSecondary },
          ]}>
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

// A section's header. A Mailbox Connection's problem shows as a warning beside its title, on iPad
// the frames' 13pt glyph at 1.15× and on iPhone at the title's 17pt, and VoiceOver reads it with
// the header.
function SectionHeader({
  label,
  trouble,
}: {
  readonly label: string;
  readonly trouble?: string | undefined;
}) {
  const colors = usePalette();
  const large = useLargeText();
  if (trouble === undefined) {
    return (
      <Text
        accessibilityRole="header"
        numberOfLines={large ? 0 : 1}
        style={[
          styles.section,
          compact && styles.compactSection,
          { color: compact ? colors.textPrimary : colors.textSecondary },
        ]}>
        {label}
      </Text>
    );
  }
  return (
    <View
      accessible
      accessibilityRole="header"
      accessibilityLabel={`${label}, ${trouble}`}
      style={compact ? styles.compactSectionRow : styles.sectionRow}>
      <Text
        numberOfLines={large ? 0 : 1}
        style={[
          styles.sectionTitle,
          compact && styles.compactSectionTitle,
          { color: compact ? colors.textPrimary : colors.textSecondary },
        ]}>
        {label}
      </Text>
      <SFSymbol
        name="exclamationmark.triangle.fill"
        color={colors.statusWarning}
        size={compact ? 17 : 12.5 * ipadListScale}
      />
    </View>
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

// A folder or Gmail view's name and SF Symbol; a connection waiting for authorization lists only
// its Inbox.
const folderLabel = (
  t: Translate,
  mailbox: InboxMailbox | undefined,
  folder: string,
) => {
  const gmail = mailbox === undefined ? undefined : gmailMailbox(mailbox);
  if (gmail !== undefined) {
    return gmailViewRow(t, gmail, folder);
  }
  return folder === inboxFolder
    ? { title: t('inbox.title'), icon: 'tray' }
    : { title: folder, icon: 'folder' };
};

// A Mailbox Connection's folder rows: an IMAP connection's folders, or a Gmail mailbox's Inbox,
// labels, All Mail, Spam and Trash. A folder or view whose last read failed keeps its warning
// after another mailbox is chosen. The connection's own problem rides on its header.
function FolderRows({
  mailbox,
  folders,
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
  // A folder or Gmail view's name, SF Symbol and failed-read notice.
  const row = (folder: string) => ({
    failure: failed.includes(JSON.stringify(folder))
      ? t('imap.foldersUnavailable')
      : undefined,
    ...folderLabel(t, mailbox, folder),
  });
  return (
    <View
      style={compact && [styles.group, { backgroundColor: colors.fillQuiet }]}>
      {folders.map(
        ({ name: folder, inbox: isInbox, unread, selected }, index) => {
          const { title: label, icon, failure } = row(folder);
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
                icon={icon}
                label={label}
                accessibilityLabel={t('inbox.rowLabel_mailbox', {
                  row: label,
                  mailbox: name,
                })}
                count={unread}
                status={failure}
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

// A Favorites row's symbol and name.
const favoriteRow = (t: Translate, row: Favorite) =>
  row === allInboxes
    ? { title: t('inbox.allInboxes'), icon: 'tray.2' }
    : unifiedRow(t, row);

// The window's Profile's Favorites as its Inbox preferences keep them, which its other Trusted
// Devices share.
function useFavorites(profile: string) {
  const store = use(InboxPreferencesContext);
  const entries = useSyncExternalStore(store.subscribe, () =>
    store.favorites(profile),
  );
  return {
    entries,
    // Applies `change` to the stored rows, so an edit made before the last one is read keeps it.
    // Resolves the rows it stored, or undefined when storage failed.
    change: async (
      change: (stored: FavoriteEntries) => FavoriteEntries | undefined,
    ) =>
      (await store.changeFavorites(profile, change))
        ? favoriteRows(store.favorites(profile))
        : undefined,
  };
}

// The order of Favorites or folder rows, to compare; JSON keeps a folder name's newline apart.
const orderOf = (
  rows: ReadonlyArray<Readonly<{ row: string }> | Readonly<{ name: string }>>,
) => JSON.stringify(rows.map((row) => ('row' in row ? row.row : row.name)));

// What a DragList gives each of its items: whether the item is lifted by a drag, which ways it can
// move by one place, and how to move it so or drag it by its handle.
type Draggable = Readonly<{
  lifted: boolean;
  moves: Readonly<{ up: boolean; down: boolean }>;
  onMove: (by: -1 | 1) => void;
  // How far the finger moved since the drag began, and where it is in the window.
  onDrag: (dy: number, pageY: number) => void;
  // How far from where the drag began the finger let go; undefined when the drag was cancelled.
  onDrop: (dy: number | undefined) => void;
}>;

// Scrolls the sidebar while a row is dragged near its top or bottom edge, as a table's reorder
// does, so a place past a tall account stays in reach. `follow` takes the finger's place in the
// window, or undefined once the drag ends, and gives `scrolled` how far the list has scrolled since
// the drag began.
type EdgeScroll = Readonly<{
  follow: (pageY: number | undefined, scrolled: (by: number) => void) => void;
}>;
const EdgeScrollContext = createContext<EdgeScroll>({
  follow: () => undefined,
});
// How near an edge, in points, a dragged row scrolls the list, the most it scrolls a frame, and how
// far the finger moves a row before the list scrolls, so a press held at an edge moves nothing.
const edgeBand = 64;
const edgeSpeed = 14;
const dragSlop = 8;

function useEdgeScroll() {
  const list = useRef<ScrollViewInstance>(null);
  // The list's offset, content height and place in the window.
  const frame = useRef({ offset: 0, content: 0, top: 0, height: 0 });
  // The drag being followed: the offset it began at, the finger and the next scroll step.
  const held = useRef<{
    origin: number;
    pageY: number;
    scrolled: (by: number) => void;
    step?: number | undefined;
  }>(undefined);
  const step = () => {
    const drag = held.current;
    if (drag === undefined) {
      return;
    }
    drag.step = undefined;
    const { offset, content, top, height } = frame.current;
    const above = drag.pageY - top;
    const below = top + height - drag.pageY;
    const pace =
      height === 0
        ? 0
        : edgeSpeed *
          (Math.max(0, 1 - below / edgeBand) -
            Math.max(0, 1 - above / edgeBand));
    const next = Math.max(0, Math.min(content - height, offset + pace));
    if (Math.abs(next - offset) >= 0.5) {
      frame.current.offset = next;
      list.current?.scrollTo({ y: next, animated: false });
      drag.scrolled(next - drag.origin);
      drag.step = requestAnimationFrame(step);
    }
  };
  const follow: EdgeScroll['follow'] = (pageY, scrolled) => {
    if (pageY === undefined) {
      if (held.current?.step !== undefined) {
        cancelAnimationFrame(held.current.step);
      }
      held.current = undefined;
      return;
    }
    if (held.current === undefined) {
      held.current = { origin: frame.current.offset, pageY, scrolled };
      list.current?.measureInWindow((_x, y) => {
        frame.current.top = y;
      });
    }
    Object.assign(held.current, { pageY, scrolled });
    held.current.step ??= requestAnimationFrame(step);
  };
  return {
    list,
    edge: { follow },
    onScroll: ({
      nativeEvent,
    }: Readonly<{
      nativeEvent: Readonly<{ contentOffset: { y: number } }>;
    }>) => {
      frame.current.offset = nativeEvent.contentOffset.y;
    },
    onContentSizeChange: (_width: number, height: number) => {
      frame.current.content = height;
    },
    onLayout: ({ nativeEvent }: LayoutChangeEvent) => {
      frame.current.height = nativeEvent.layout.height;
    },
  };
}

// Items an Edit mode list reorders: one dragged by its handle moves to where it is dropped, the
// items it passes giving way, each as tall as it lays out. A drag ends without a move when the
// items change order meanwhile, as when another device reorders them.
function DragList<T>({
  items,
  keyOf,
  separator,
  onMove,
  onDragging,
  render,
}: {
  readonly items: readonly T[];
  readonly keyOf: (item: T) => string;
  // Drawn between items, as iPhone's hairlines.
  readonly separator?: ReactNode;
  // Moves item `key` to the place `to` gives for its stored place.
  readonly onMove: (key: string, to: (index: number) => number) => void;
  // Whether an item is being dragged, while the list must not scroll.
  readonly onDragging: (dragging: boolean) => void;
  readonly render: (item: T, drag: Draggable) => ReactNode;
}) {
  const edge = use(EdgeScrollContext);
  const keys = items.map(keyOf);
  const order = JSON.stringify(keys);
  // The dragged item, the place it started from, how far the finger and the list moved it, whether
  // it has moved past `dragSlop`, the items' order when it began, and whether a new order ended it.
  const [held, setHeld] = useState<
    Readonly<{
      key: string;
      from: number;
      dy: number;
      scrolled: number;
      moved: boolean;
      order: string;
      cancelled?: boolean;
    }>
  >();
  // A drag whose item leaves the list gets no release, so it ends here and the next one can start.
  if (held !== undefined && !keys.includes(held.key)) {
    setHeld(undefined);
  }
  const drag = held?.order === order && !held.cancelled ? held : undefined;
  // A drag that ends, that the items' new order cancels for good, or whose list leaves stops
  // scrolling the list and lets it scroll again.
  const stop = useEffectEvent(() => {
    edge.follow(undefined, () => undefined);
    onDragging(false);
    setHeld((kept) => kept && { ...kept, cancelled: true });
  });
  const active = drag !== undefined;
  useEffect(
    () =>
      active
        ? () => {
            stop();
          }
        : undefined,
    [active],
  );
  const [heights, setHeights] = useState<ReadonlyMap<string, number>>(
    new Map(),
  );
  const height = (index: number) => heights.get(keys[index] ?? '') ?? 0;
  // The place `dy` from item `from` falls on: past each laid-out item whose middle it crosses.
  const place = (from: number, dy: number) => {
    const step = dy < 0 ? -1 : 1;
    let to = from;
    let rest = Math.abs(dy);
    while (height(to + step) > 0 && rest > height(to + step) / 2) {
      rest -= height(to + step);
      to += step;
    }
    return to;
  };
  const from = drag?.from ?? -1;
  const dy = drag === undefined ? 0 : drag.dy + drag.scrolled;
  const to = drag === undefined ? from : place(from, dy);
  // How far the items the dragged one passed reach.
  let passed = 0;
  for (
    let index = Math.min(from, to);
    index <= Math.max(from, to);
    index += 1
  ) {
    passed += index === from ? 0 : height(index);
  }
  const dragged = items.find((item) => keyOf(item) === drag?.key);
  const rest = items.filter((item) => item !== dragged);
  const shown =
    dragged === undefined
      ? items
      : [...rest.slice(0, to), dragged, ...rest.slice(to)];
  return shown.map((item, position) => {
    const key = keyOf(item);
    const index = keys.indexOf(key);
    // Where this item's drag began, or its place now when no drag of it has rendered yet, such
    // as a press and release in one event batch.
    const begin = drag?.key === key ? drag.from : index;
    const lifted = drag !== undefined && item === dragged;
    return (
      <Fragment key={key}>
        {position > 0 ? separator : null}
        <View
          onLayout={({ nativeEvent }) => {
            const { height: laid } = nativeEvent.layout;
            setHeights((kept) =>
              kept.get(key) === laid ? kept : new Map(kept).set(key, laid),
            );
          }}
          style={
            lifted && {
              zIndex: 1,
              transform: [{ translateY: dy - (to < from ? -passed : passed) }],
            }
          }>
          {render(item, {
            lifted,
            moves: { up: index > 0, down: index < items.length - 1 },
            onMove: (by) => {
              onMove(key, (stored) => stored + by);
            },
            onDrag: (finger, pageY) => {
              if (held !== undefined && drag === undefined) {
                return;
              }
              onDragging(true);
              const moved =
                (drag?.moved ?? false) || Math.abs(finger) >= dragSlop;
              setHeld({
                key,
                from: begin,
                dy: finger,
                scrolled: drag?.scrolled ?? 0,
                moved,
                order,
              });
              if (moved) {
                edge.follow(pageY, (by) => {
                  setHeld((kept) => kept && { ...kept, scrolled: by });
                });
              }
            },
            onDrop: (finger) => {
              edge.follow(undefined, () => undefined);
              setHeld(undefined);
              const at =
                finger === undefined || drag === undefined
                  ? index
                  : place(begin, finger + drag.scrolled);
              // The drop moves the row before the drag ends, so it moves from where the drag began.
              if (at !== index) {
                onMove(key, () => at);
              }
              onDragging(false);
            },
          })}
        </View>
      </Fragment>
    );
  });
}

// An Edit row's name: a connection header's title fills the row as its header's does.
const editLabel = (header: boolean) => {
  if (header) {
    return [
      compact ? styles.compactSectionTitle : styles.sectionTitle,
      styles.grow,
    ];
  }
  return compact ? styles.compactLabel : styles.label;
};

// A row in Edit mode: the checkmark that shows or hides it, its symbol and name, and the handle
// that drags it to another place. Tapping the row shows or hides it; Move Up and Move Down reorder
// it with VoiceOver and Full Keyboard Access. A Mailbox Connection's header row has no symbol.
function EditRow({
  title,
  icon,
  accessibilityLabel = title,
  shown,
  drag,
  onToggle,
}: {
  readonly title: string;
  readonly icon?: string;
  readonly accessibilityLabel?: string;
  readonly shown: boolean;
  readonly drag: Draggable;
  readonly onToggle: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const large = useLargeText();
  // Where the finger pressed the handle.
  const start = useRef(0);
  const slot = compact ? styles.compactSlot : styles.checkSlot;
  const header = icon === undefined;
  return (
    <Pressable
      accessibilityActions={[
        ...(drag.moves.up
          ? [{ name: 'moveUp', label: t('mailboxes.moveUp') }]
          : []),
        ...(drag.moves.down
          ? [{ name: 'moveDown', label: t('mailboxes.moveDown') }]
          : []),
      ]}
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      accessibilityValue={{
        text: t(shown ? 'mailboxes.shown' : 'mailboxes.hidden'),
      }}
      onAccessibilityAction={({ nativeEvent }) => {
        drag.onMove(nativeEvent.actionName === 'moveUp' ? -1 : 1);
      }}
      onPress={onToggle}
      style={({ pressed }) => [
        styles.row,
        compact ? styles.compactEditRow : styles.editRow,
        header && (compact ? styles.compactEditHeader : styles.editHeader),
        (pressed || drag.lifted) && {
          backgroundColor: colors.accentSelectionSubtle,
        },
      ]}>
      <View style={slot}>
        <SFSymbol
          name={shown ? 'checkmark.circle.fill' : 'circle'}
          color={shown ? colors.accentFill : colors.textSecondary}
          size={compact ? 22 : 16}
        />
      </View>
      {header ? null : (
        <View style={compact ? styles.compactSlot : styles.editIcon}>
          <SFSymbol
            name={icon}
            color={colors.accentInk}
          />
        </View>
      )}
      <Text
        numberOfLines={large ? 0 : 1}
        style={[
          editLabel(header),
          // iPad dims a hidden row's name, as the frames draw it; iPhone keeps it.
          {
            color: shown || compact ? colors.textPrimary : colors.textSecondary,
          },
        ]}>
        {title}
      </Text>
      <View
        onStartShouldSetResponder={() => true}
        // The handle keeps the finger once it has it; the list does not scroll meanwhile.
        onResponderTerminationRequest={() => false}
        onResponderGrant={({ nativeEvent }) => {
          start.current = nativeEvent.pageY;
          drag.onDrag(0, nativeEvent.pageY);
        }}
        onResponderMove={({ nativeEvent }) => {
          drag.onDrag(nativeEvent.pageY - start.current, nativeEvent.pageY);
        }}
        onResponderRelease={({ nativeEvent }) => {
          drag.onDrop(nativeEvent.pageY - start.current);
        }}
        onResponderTerminate={() => {
          drag.onDrop(undefined);
        }}
        // The handle takes the row's height and 44pt of its width.
        hitSlop={{ left: 13, right: 13 }}
        style={[slot, styles.handle]}>
        <SFSymbol
          name="line.3.horizontal"
          color={colors.textSecondary}
          size={compact ? 18 : 14}
        />
      </View>
    </Pressable>
  );
}

// iPhone's hairline between Edit rows, from the label to the group's edge.
function EditSeparator() {
  const colors = usePalette();
  return compact ? (
    <View
      style={[
        styles.separator,
        styles.editSeparator,
        { backgroundColor: colors.separator },
      ]}
    />
  ) : null;
}

type SidebarEntry = ReturnType<
  typeof mailboxSidebar<InboxMailbox, MailboxConnection>
>['entries'][number];

// A Mailbox Connection's address, and its header title: its provider and address.
const connectionNames = (t: Translate, entry: SidebarEntry) => {
  const { provider, address } =
    'section' in entry
      ? {
          provider: entry.section.mailbox.provider ?? 'gmail',
          address: entry.section.mailbox.address ?? entry.id,
        }
      : entry.waiting.connection;
  return { address, title: `${t(`mailProviders.${provider}`)} · ${address}` };
};

// `folders` of `connection` in the Profile's order, without those it hides.
const shownFolders = <F extends Readonly<{ name: string }>>(
  stored: SectionFolders,
  folders: readonly F[],
) =>
  folderRows(
    stored,
    folders.map(({ name }) => name),
  ).flatMap(({ name, shown }) =>
    shown ? folders.filter((folder) => folder.name === name) : [],
  );

// Selects `next` in place of a row Edit hid in Mail Profile `profile`, when the window's selection
// in that Profile is still one that `hidden` matches, however long the write took.
type Hidden = (
  profile: string,
  hidden: (view: MailboxView) => boolean,
  next: MailboxView,
) => void;

// The Profile's Mailbox Connections in Edit mode, in its order: a header's checkmark shows or hides
// the connection and its handle drags it with its folders; a shown connection lists its folders to
// show, hide and reorder, its Inbox staying shown. Hiding the selected connection or folder selects
// All Inboxes. A refused reorder says so.
function EditConnections({
  entries,
  onHidden,
  onDragging,
}: {
  readonly entries: readonly SidebarEntry[];
  readonly onHidden: Hidden;
  readonly onDragging: (dragging: boolean) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const account = use(AccountContext);
  const profile = useProfile();
  const store = use(InboxPreferencesContext);
  const sections = useSections(profile);
  const leave = (connection: string, folder?: string) => {
    onHidden(
      profile,
      (selected) =>
        selected.mailbox === connection &&
        (folder === undefined || selected.folder === folder),
      {},
    );
  };
  const showOrHide = async (connection: string, shown: boolean) => {
    if ((await store.showSection(profile, connection, !shown)) && shown) {
      leave(connection);
    }
  };
  // A tap stores the opposite of what the row showed, whatever another write stored meanwhile.
  const showOrHideFolder = async (
    connection: string,
    names: readonly string[],
    folder: Readonly<{ name: string; shown: boolean }>,
  ) => {
    const { name } = folder;
    const stored = await store.changeFolders(profile, connection, (folders) =>
      showFolder(folders, names, { name, shown: !folder.shown }),
    );
    const hidden = folderRows(
      sectionFolders(store.sections(profile) ?? {}, connection),
      names,
    ).some((row) => row.name === name && !row.shown);
    if (stored && hidden) {
      leave(connection, name);
    }
  };
  const connections = profileMailboxes(account?.mailboxes ?? [], profile).map(
    ({ id }) => id,
  );
  // The Profile's full order when a drag began, so a change to it during the drag, even of a
  // connection without a row, cancels the drop; Move Up and Move Down move from the order shown.
  const began = useRef<readonly string[] | undefined>(undefined);
  const arrange = async (order: readonly string[], from: readonly string[]) => {
    if (
      account?.arrangeMailboxes !== undefined &&
      !(await account.arrangeMailboxes(profile, order, from))
    ) {
      Alert.alert(t('mailboxes.orderFailed'), t('mailboxes.orderTryAgain'), [
        { text: t('common.ok') },
      ]);
    }
  };
  return (
    <DragList
      items={entries}
      keyOf={({ id }) => id}
      onMove={(key, to) => {
        // The drop's place among the rows, before the next row's connection in the Profile's
        // order, so a connection without a row, such as one not yet opened, keeps its place.
        const keys = entries.map(({ id }) => id);
        const rest = keys.filter((id) => id !== key);
        const place = Math.max(0, to(keys.indexOf(key)));
        const from = began.current ?? connections;
        const order = from.filter((id) => id !== key);
        const next = rest.slice(place).find((id) => order.includes(id));
        order.splice(
          next === undefined ? order.length : order.indexOf(next),
          0,
          key,
        );
        void arrange(order, from);
      }}
      onDragging={(dragging) => {
        // Each step of a drag reports it; its drop moves the row before it ends.
        began.current = dragging ? (began.current ?? connections) : undefined;
        onDragging(dragging);
      }}
      render={(entry, drag) => {
        const { id } = entry;
        const mailbox = 'section' in entry ? entry.section.mailbox : undefined;
        const names =
          'section' in entry
            ? entry.section.folders.map(({ name }) => name)
            : [inboxFolder];
        const shown = sectionShown(sections, id);
        const { title, address } = connectionNames(t, entry);
        return (
          <>
            <EditRow
              title={title}
              shown={shown}
              drag={drag}
              onToggle={() => {
                void showOrHide(id, shown);
              }}
            />
            {shown ? (
              <View
                style={
                  compact && [
                    styles.group,
                    { backgroundColor: colors.fillQuiet },
                  ]
                }>
                <DragList
                  items={folderRows(sectionFolders(sections, id), names)}
                  keyOf={({ name }) => name}
                  separator={<EditSeparator />}
                  onMove={(name, to) => {
                    // A drop onto rows another device has reordered since changes nothing.
                    const seen = orderOf(
                      folderRows(sectionFolders(sections, id), names),
                    );
                    void store.changeFolders(profile, id, (folders) =>
                      orderOf(folderRows(folders, names)) === seen
                        ? moveFolder(folders, names, { name, to })
                        : undefined,
                    );
                  }}
                  onDragging={onDragging}
                  render={(folder, folderDrag) => (
                    <EditRow
                      {...folderLabel(t, mailbox, folder.name)}
                      accessibilityLabel={t('inbox.rowLabel_mailbox', {
                        row: folderLabel(t, mailbox, folder.name).title,
                        mailbox: address,
                      })}
                      shown={folder.shown}
                      drag={folderDrag}
                      onToggle={() => {
                        void showOrHideFolder(id, names, folder);
                      }}
                    />
                  )}
                />
              </View>
            ) : null}
          </>
        );
      }}
    />
  );
}

// Edit, beside Account on iPhone and the sidebar toggle on iPad, and Done, which replaces both on
// iPhone: the system's buttons, as the frames draw them. Mailboxes without an account offer none.
// Whether Mailboxes is in Edit mode: never while the Profile's preferences are unread, so no write
// starts from rows not read.
function useEditing(readable: boolean) {
  const [editing, setEditing] = useState(false);
  // A command offered while they were read can still run after a reread fails: it opens nothing.
  if (editing && !readable) {
    setEditing(false);
  }
  return {
    editing: editing && readable,
    setEditing: (next: boolean) => {
      setEditing(next && readable);
    },
  };
}

// Edit waits for the Profile's preferences, so it never edits rows it has not read.
function EditButton({
  editing,
  available,
  onEditing,
}: {
  readonly editing: boolean;
  readonly available: boolean;
  readonly onEditing: (editing: boolean) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const account = use(AccountContext);
  if (account === undefined) {
    return null;
  }
  const done = compact
    ? [
        labelStyle('iconOnly'),
        buttonStyle('glassProminent'),
        buttonBorderShape('circle'),
        controlSize('large'),
      ]
    : [
        buttonStyle('borderedProminent'),
        buttonBorderShape('capsule'),
        controlSize('small'),
      ];
  const button = (
    <Host matchContents>
      {editing ? (
        <SwiftUIButton
          label={t('mailboxes.done')}
          {...(compact ? { systemImage: 'checkmark' } : {})}
          modifiers={[...done, tint(colors.accentFill)]}
          onPress={() => {
            onEditing(false);
          }}
        />
      ) : (
        <SwiftUIButton
          label={t('mailboxes.edit')}
          modifiers={[
            buttonStyle(compact ? 'glass' : 'borderless'),
            controlSize(compact ? 'large' : 'regular'),
            tint(colors.textPrimary),
            disabled(!available),
          ]}
          onPress={() => {
            onEditing(true);
          }}
        />
      )}
    </Host>
  );
  return compact ? button : <View style={styles.panelButton}>{button}</View>;
}

// Favorites: All Inboxes and the Unified Mailboxes the Profile shows, in its order, with the
// Outbox after Sent while it holds a message; in Edit mode, every row with its checkmark and handle.
function Favorites({
  view,
  onView,
  onHidden,
  onOutbox,
  unread,
  allSelected,
  editing,
  onDragging,
}: {
  readonly view: MailboxView;
  readonly onView: (view: MailboxView) => void;
  readonly onHidden: Hidden;
  readonly onOutbox?: () => void;
  // All Inboxes' unread count, and whether it is selected.
  readonly unread: number;
  readonly allSelected: boolean;
  readonly editing: boolean;
  readonly onDragging: (dragging: boolean) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const outbox = useProfileOutbox();
  const profile = useProfile();
  const { entries, change } = useFavorites(profile);
  const rows = favoriteRows(entries);
  const shownRows = rows.filter(({ shown }) => shown);
  // Hiding the selected Unified Mailbox selects the first row still shown.
  const showOrHide = async (row: Favorite, showing: boolean) => {
    const after = await change((stored) => showFavorite(stored, row, !showing));
    if (after?.some((entry) => entry.row === row && !entry.shown) === true) {
      const first = after.find(({ shown }) => shown)?.row;
      onHidden(
        profile,
        (selected) => selected.unified === row,
        first === undefined || first === allInboxes ? {} : { unified: first },
      );
    }
  };
  if (editing) {
    return (
      <View
        style={
          compact && [styles.group, { backgroundColor: colors.fillQuiet }]
        }>
        <DragList
          items={rows}
          keyOf={({ row }) => row}
          separator={<EditSeparator />}
          onMove={(key, to) => {
            const row = rows.find((entry) => entry.row === key)?.row;
            if (row !== undefined) {
              // A drop onto rows another device has reordered since changes nothing.
              const seen = orderOf(rows);
              void change((stored) =>
                orderOf(favoriteRows(stored)) === seen
                  ? moveFavorite(
                      stored,
                      row,
                      to(
                        favoriteRows(stored).findIndex(
                          (entry) => entry.row === row,
                        ),
                      ),
                    )
                  : undefined,
              );
            }
          }}
          onDragging={onDragging}
          render={({ row, shown }, drag) => (
            <EditRow
              {...favoriteRow(t, row)}
              shown={shown}
              drag={drag}
              onToggle={() => {
                void showOrHide(row, shown);
              }}
            />
          )}
        />
      </View>
    );
  }
  // The Outbox follows Sent, or ends Favorites while Sent is hidden. iPhone's grouped rows are
  // divided by hairlines.
  const separator = compact ? (
    <View style={[styles.separator, { backgroundColor: colors.separator }]} />
  ) : null;
  const outboxRow =
    onOutbox !== undefined && outbox.length > 0 ? (
      <>
        {separator}
        <Item
          icon="tray.and.arrow.up"
          label={t('outbox.heading')}
          selected={view.outbox === true}
          onPress={onOutbox}
        />
      </>
    ) : null;
  return (
    <View
      style={compact && [styles.group, { backgroundColor: colors.fillQuiet }]}>
      {shownRows.map(({ row }, index) => {
        const { title, icon } = favoriteRow(t, row);
        return (
          <Fragment key={row}>
            {index > 0 ? separator : null}
            {row === allInboxes ? (
              <Item
                icon={icon}
                label={title}
                count={unread}
                selected={allSelected && view.outbox !== true}
                onPress={() => {
                  onView({});
                }}
              />
            ) : (
              <Item
                icon={icon}
                label={title}
                accessibilityLabel={t('inbox.rowLabel_mailbox', {
                  row: title,
                  mailbox: t('mailboxes.allMailboxes'),
                })}
                selected={view.unified === row}
                onPress={() => {
                  onView({ unified: row });
                }}
              />
            )}
            {row === 'SENT' ? outboxRow : null}
          </Fragment>
        );
      })}
      {shownRows.some(({ row }) => row === 'SENT') ? null : outboxRow}
    </View>
  );
}

// The Mailboxes of the window's Profile: every Inbox together, the Unified Mailboxes with the
// Outbox after Sent while it holds a message, then each Mailbox Connection with its folders, and
// Settings last.
export function Mailboxes({
  view,
  onView,
  onSelect = onView,
  onOutbox,
  onProfile,
  onCompose,
  bar,
}: {
  readonly view: MailboxView;
  readonly onView: (view: MailboxView) => void;
  // Selects `view` without opening its list, as when Favorites hides the selected Unified Mailbox.
  readonly onSelect?: (view: MailboxView) => void;
  // Shows the Outbox, ending a search, each time it is chosen; Mailboxes without it offer none.
  readonly onOutbox?: () => void;
  // Switches the window to another Mail Profile.
  readonly onProfile: (profile: string) => void;
  // Opens a new Draft's composer from iPhone's New Message; none where Mailboxes offers no composer.
  readonly onCompose?: (id: string) => void;
  // iPhone's single column, whose navigation bar the Inbox shows and Mailboxes hides.
  readonly bar?: boolean;
}) {
  const mailboxes = useMailboxes();
  const account = use(AccountContext);
  const profile = useProfile();
  const reload = useReloadMailboxes();
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  // iPhone's list runs under the home indicator, behind New Message's scroll edge.
  const { bottom } = useSafeAreaInsets();
  const toggle = use(SidebarToggleContext);
  const sidebar = mailboxSidebar({
    mailboxes,
    connections: account?.mailboxes ?? [],
    profile,
    view,
  });
  // The connections the Profile shows, which All Inboxes counts; none until the Profile's
  // preferences are read, as All Inboxes lists none. Edit mode lists every one.
  const read = useReadSections(profile);
  // Edit Favorites, and whether a row is being dragged, while the list must not scroll.
  const { editing, setEditing } = useEditing(read !== undefined);
  const shown = sidebar.entries.filter(
    ({ id }) => read !== undefined && sectionShown(read, id),
  );
  const unread = shown.reduce(
    (sum, entry) => sum + ('section' in entry ? entry.section.unread : 0),
    0,
  );
  const [dragging, setDragging] = useState(false);
  const { list, edge, onScroll, onContentSizeChange, onLayout } =
    useEdgeScroll();
  // The window's Profile and selection now, which an Edit write may outlive, even past Done.
  const latest = useRef({ profile, view });
  useLayoutEffect(() => {
    latest.current = { profile, view };
  });
  const leave: Hidden = (from, hidden, next) => {
    const { profile: now, view: selected } = latest.current;
    if (now === from && hidden(selected)) {
      onSelect(next);
    }
  };
  const editButton = (
    <EditButton
      editing={editing}
      available={read !== undefined}
      onEditing={setEditing}
    />
  );
  // Settings over Mailboxes: Back returns here; Open Inbox shows the kept list, as choosing it would.
  const openSettings = (destination?: SettingsDestination) => {
    account?.openAccount(destination, () => {
      onView(view);
    });
  };
  const authorize = async (connection: string) => {
    await account?.authorizeMailbox(connection);
    await reload();
  };
  // iPhone's Authorization Needed banner above a connection's folders: Sign In… asks its provider
  // again, and IMAP enters its password again in Settings' Email Accounts. VoiceOver hears the
  // action with the connection's address, since several connections can need it.
  const signInNotice = ({
    provider,
    address,
    imap,
    onSignIn,
  }: Readonly<{
    provider: string;
    address: string;
    imap: boolean;
    onSignIn: () => Promise<void>;
  }>) =>
    compact ? (
      <SignInNotice
        message={
          imap
            ? t('mailboxes.passwordNotice')
            : t('mailboxes.signInNotice', { provider })
        }
        action={
          imap ? t('mailboxes.enterPasswordAction') : t('mailboxes.signIn')
        }
        accessibilityLabel={
          imap
            ? t('mailboxes.enterPasswordFor', { address })
            : t('mailboxes.signInFor', { address })
        }
        onPress={() => {
          if (imap) {
            openSettings('mailboxes');
          } else {
            void onSignIn();
          }
        }}
        style={styles.compactNotice}
      />
    ) : null;
  return (
    // The safe area keeps its insets as margins, so on iPhone the surface around it fills the
    // screen behind the status bar and home indicator.
    <View style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <RegisterCommands
        offer={() =>
          // Edit Favorites while the iPad sidebar shows beside the list; iPhone's Mailboxes has its
          // Edit button. The Inbox offers Go To each Unified Mailbox.
          sidebarCommands(t, {
            favorites:
              !compact && account !== undefined && toggle?.shown === true
                ? () => {
                    setEditing(true);
                  }
                : undefined,
          })
        }
      />
      {bar === true ? <NavigationChrome /> : null}
      <SafeAreaView
        edges={{
          top: true,
          bottom: compact && onCompose === undefined,
          left: true,
          right: true,
        }}
        style={styles.fill}>
        <View
          style={
            compact
              ? styles.fill
              : [
                  styles.panel,
                  {
                    backgroundColor: colors.surfacePanel,
                    borderColor: colors.separator,
                    boxShadow: colors.largeGlassShadow,
                  },
                ]
          }>
          {compact ? null : (
            <View style={styles.panelTop}>
              {editButton}
              <SidebarToggle />
            </View>
          )}
          {/* On iPhone the header opens the Command Palette by a downward swipe or its
            accessibility action. The iPad sidebar has no heading: the frames start it with the
            Profile Switcher beneath the column's sidebar toggle. */}
          {compact ? (
            <View
              style={styles.compactHeading}
              {...header.swipe}>
              <View style={styles.grow} />
              <Text
                accessibilityRole="header"
                style={[styles.title, { color: colors.textPrimary }]}
                {...header.action}>
                {t('mailboxes.title')}
              </Text>
              <View style={[styles.grow, styles.headingActions]}>
                {editButton}
                {account === undefined || editing ? null : (
                  <GlassGroup style={styles.accountGlass}>
                    <Pressable
                      accessibilityLabel={t('inbox.account')}
                      accessibilityRole="button"
                      onPress={() => {
                        openSettings();
                      }}
                      style={styles.accountButton}>
                      {/* The frames' gear draws 16pt of ink. */}
                      <SFSymbol
                        name="gearshape"
                        size={15.5}
                        color={colors.textPrimary}
                      />
                    </Pressable>
                  </GlassGroup>
                )}
              </View>
            </View>
          ) : null}
          <EdgeScrollContext value={edge}>
            <ScrollView
              ref={list}
              style={styles.fill}
              scrollEnabled={!dragging}
              onScroll={onScroll}
              scrollEventThrottle={16}
              onContentSizeChange={onContentSizeChange}
              onLayout={onLayout}
              // A row takes its first tap while Search's keyboard is up, so one tap on Outbox ends
              // the search.
              keyboardShouldPersistTaps="handled"
              contentContainerStyle={[
                styles.list,
                compact && styles.compactList,
                compact &&
                  onCompose !== undefined && {
                    paddingBottom: styles.compactList.paddingBottom + bottom,
                  },
              ]}>
              <ProfileSwitcher
                onProfile={onProfile}
                onManage={() => {
                  openSettings('profiles');
                }}
              />
              <SectionHeader label={t('mailboxes.favorites')} />
              <Favorites
                view={view}
                onView={onView}
                onHidden={leave}
                unread={unread}
                allSelected={sidebar.allSelected}
                editing={editing}
                onDragging={setDragging}
                {...(onOutbox === undefined ? {} : { onOutbox })}
              />
              {editing ? (
                <EditConnections
                  entries={sidebar.entries}
                  onHidden={leave}
                  onDragging={setDragging}
                />
              ) : (
                shown.map((entry) => {
                  if ('section' in entry) {
                    const { mailbox, folders } = entry.section;
                    // Waiting out Gmail's usage limit is a pause the Sync Status Capsule reports.
                    const problem = limited(mailbox.state)
                      ? undefined
                      : entry.section.problem;
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
                        <SectionHeader
                          label={`${provider} · ${name}`}
                          trouble={trouble}
                        />
                        {problem === 'authentication'
                          ? signInNotice({
                              provider,
                              address: name,
                              imap: mailbox.provider === 'imap',
                              onSignIn: async () => {
                                await account?.authorizeMailbox(mailbox.id);
                                await mailbox.inbox.load();
                              },
                            })
                          : null}
                        <FolderRows
                          mailbox={mailbox}
                          folders={shownFolders(
                            sectionFolders(read ?? {}, mailbox.id),
                            folders,
                          )}
                          onView={onView}
                        />
                      </Fragment>
                    );
                  }
                  const { connection, recovery, selected } = entry.waiting;
                  const provider = t(`mailProviders.${connection.provider}`);
                  const imap = recovery === 'account';
                  const trouble = imap
                    ? t('mailboxes.states.imap-authorization')
                    : t('mailboxes.states.authorization', { provider });
                  return (
                    <Fragment key={connection.id}>
                      <SectionHeader
                        label={`${provider} · ${connection.address}`}
                        trouble={trouble}
                      />
                      {signInNotice({
                        provider,
                        address: connection.address,
                        imap,
                        onSignIn: () => authorize(connection.id),
                      })}
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
                          selected={selected}
                          onPress={() => {
                            // IMAP needs its password entered again in Settings' Email Accounts.
                            if (imap) {
                              openSettings('mailboxes');
                            } else {
                              void authorize(connection.id);
                            }
                          }}
                        />
                      </View>
                    </Fragment>
                  );
                })
              )}
            </ScrollView>
          </EdgeScrollContext>
          {compact && onCompose !== undefined ? (
            <FloatingBar
              bottomInset={bottom}
              // The frames fade the last 140pt of Mailboxes behind New Message.
              edge={140}
              leading={null}
              trailing={
                <NewMessageButton
                  onCompose={onCompose}
                  scope={undefined}
                  registerCommand={false}
                />
              }>
              <BarSpacer />
            </FloatingBar>
          ) : null}
          {compact || account === undefined ? null : (
            <View style={[styles.footer, { borderTopColor: colors.separator }]}>
              <Item
                icon="gearshape"
                label={t('settings.title')}
                onPress={() => {
                  openSettings();
                }}
              />
            </View>
          )}
        </View>
      </SafeAreaView>
    </View>
  );
}
