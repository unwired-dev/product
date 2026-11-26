import type { CommandTarget } from '@private-email/mail-core/commands';
import type { MenuItem } from '@private-email/mail-core/context-menu';
import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type {
  ImapAction,
  ImapInbox,
} from '@private-email/mail-core/imap-inbox';
import type { PersistentInbox } from '@private-email/mail-core/persistent-inbox';
import type { ReactElement, ReactNode, RefObject } from 'react';

import {
  BottomSheet,
  Group,
  Host,
  Popover,
  RNHostView,
} from '@expo/ui/swift-ui';
import {
  presentationBackground,
  presentationDetents,
} from '@expo/ui/swift-ui/modifiers';
import {
  commandTarget,
  organizeCommands,
} from '@private-email/mail-core/commands';
import {
  canOrganize,
  gmailAction,
  leavesView,
  quickActions,
} from '@private-email/mail-core/gmail-actions';
import {
  imapMoveTargets,
  imapQuickActions,
} from '@private-email/mail-core/imap-actions';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  listedMessage,
  viewMessage,
} from '@private-email/mail-core/inbox-store';
import { gmailViewName } from '@private-email/mail-core/mailboxes';
import { ipadListScale, spacing } from '@private-email/mail-core/theme';
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { Platform, StyleSheet, View } from 'react-native';

import type { Destination } from './move-sheet.tsx';
import type { ThreadAction } from './reply-sheet.tsx';

import { RegisterCommands } from './command-palette.tsx';
import {
  GlassGroup,
  MenuButton,
  Notice,
  scaledToolbar,
  scaledToolbarSlop,
  SFSymbol,
  ToolbarButton,
} from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  useInbox,
  useInboxActions,
  useMailbox,
  useProviderName,
} from './mailbox.tsx';
import { MovePanel, MoveSheet } from './move-sheet.tsx';
import { LabelChoices, NewLabel } from './new-label.tsx';
import { usePinAction, usePinned } from './pins.tsx';
import { ThreadActionsContext } from './reply-sheet.tsx';
import { useAppearance, usePalette } from './theme.ts';
import { useUnsubscribeItems } from './unsubscribe.tsx';

const compact = Platform.OS === 'ios' && !Platform.isPad;

// iPhone moves in a system sheet; iPad in a system popover on the toolbar's Move.
const MovePicker = compact ? MoveSheet : MovePanel;
const placed = (picker: ReactElement) =>
  compact ? { sheet: picker } : { popover: picker };

// The toolbar panel a reader shows: the folders or labels to move to, or More's remaining actions.
// Beside the iPhone Reply sheet, which offers those actions, it shows only the labels to add or
// remove. New Label… among the labels opens Labels, to create one.
export type ReaderPanel = 'folders' | 'more' | 'newLabel';

// Gmail's labels to add or remove, given what New Label… runs.
type Labels = (newLabel: () => void) => ReactElement;

// The iPad reader toolbar's top edge sits 15.3pt beneath the safe area, at y47.3 as the frames draw
// it, so its centre shares the top row's line 36pt beneath the safe area.
export const readerToolbarInset = 15.3;

// At most one panel is open, and the reader holds which.
type PanelState = Readonly<{
  panel: ReaderPanel | undefined;
  onPanel: (panel: ReaderPanel | undefined) => void;
}>;

const styles = StyleSheet.create({
  toolbar: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  // The iPad toolbar's More, sized as the scaled group's other buttons.
  moreButton: {
    width: scaledToolbar.width,
    height: scaledToolbar.height,
    alignItems: 'center',
  },
  // The iPhone toolbar's More, sized as its other buttons.
  compactMoreButton: { width: 44, height: 44, alignItems: 'center' },
  groups: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 * ipadListScale },
});

// Folders the server declares a role for show its SF Symbol, as the Move picker lists them.
const roleIcons: Readonly<Record<string, string>> = {
  archive: 'archivebox',
  drafts: 'doc',
  sent: 'paperplane',
  junk: 'xmark.bin',
  trash: 'trash',
};
// The SF Symbols the iPhone Reply sheet shows beside each organizing action.
const actionIcons: Readonly<Record<string, string>> = {
  read: 'envelope.open',
  unread: 'envelope.badge',
  spam: 'xmark.bin',
  trash: 'trash',
  restore: 'tray.and.arrow.down',
  notSpam: 'tray.and.arrow.down',
  pin: 'pin',
  unpin: 'pin.slash',
};
type Named = Readonly<{ name: string; label: string; run: () => void }>;

// Pin or Unpin for the reader's message: its Thread in the reader's Mailbox Connection.
type PinAction = Named &
  Readonly<{ name: 'pin' | 'unpin'; target: CommandTarget }>;

// Pin or Unpin for a message of the reader's mailbox.
function usePinFor() {
  const mailbox = useMailbox();
  const pinned = usePinned(mailbox === undefined ? [] : [mailbox.id]);
  const action = usePinAction();
  return (
    message: Readonly<{ id: string; subject: string; threadId?: string }>,
  ): PinAction | undefined =>
    mailbox === undefined
      ? undefined
      : {
          ...action(mailbox.id, message, pinned(mailbox.id, message)),
          target: commandTarget(mailbox.id, message),
        };
}

const folderIcon = (name: string, roles: readonly string[]) => {
  if (name === inboxFolder) {
    return 'tray';
  }
  const role = roles.find((declared) => declared in roleIcons);
  return role === undefined ? 'folder' : (roleIcons[role] ?? 'folder');
};

// The Inbox and folders nested in it show its localized name, so they nest beneath its row.
const localizedPath = (path: readonly string[], inbox: string) =>
  path.map((part, index) =>
    index === 0 && part === inboxFolder ? inbox : part,
  );

// The Inbox's unread mail this device holds, as the mailbox list counts it; none shows no count.
const inboxUnread = (messages: ReadonlyArray<Readonly<{ unread: boolean }>>) =>
  messages.filter(({ unread }) => unread).length || undefined;

// The message a reader last marked read on opening, and its mailbox's store, kept above the
// provider's actions so a remounted toolbar cannot mark it again.
export type Marked = RefObject<
  Readonly<{ store: object; id: string }> | undefined
>;

// Opening a message reads it: once the reader can change the message, it marks it read with the
// change Mark as Read makes. Each opening marks it once, so a later Mark as Unread stands.
export function ReadWhenOpened<M extends Readonly<{ id: string }>>({
  markedRef,
  store,
  message,
  read,
}: {
  readonly markedRef: Marked;
  readonly store: object;
  readonly message: M;
  readonly read: (message: M) => Promise<unknown>;
}) {
  useEffect(() => {
    const marked = markedRef.current;
    if (marked?.store !== store || marked.id !== message.id) {
      const opening = { store, id: message.id };
      markedRef.current = opening;
      // A read the mailbox could not save marks it again once the reader can change it.
      const mark = async () => {
        if ((await read(message)) === false && markedRef.current === opening) {
          markedRef.current = undefined;
        }
      };
      void mark();
    }
  }, [markedRef, store, message, read]);
  return null;
}

// The reader's actions for the message's provider: one glass toolbar of Archive, Move, the
// response actions passed as children, and More, whose panel lists the remaining actions. iPhone
// leaves out More while its Reply sheet offers them.
export function MessageActions({
  id,
  folder,
  onClose,
  panel,
  onPanel,
  children,
}: PanelState & {
  readonly id: string;
  // The Gmail view the message was chosen in, when not the Inbox.
  readonly folder?: string | undefined;
  readonly onClose?: (() => void) | undefined;
  readonly children?: ReactNode;
}) {
  const store = useInboxActions();
  // The message this reader last marked read on opening.
  const markedRef: Marked = useRef(undefined);
  if ('setUnread' in store) {
    return (
      <PreviewMessageActions
        id={id}
        inbox={store}
        markedRef={markedRef}
      />
    );
  }
  return 'openFolder' in store ? (
    <ImapMessageActions
      id={id}
      inbox={store}
      markedRef={markedRef}
      onClose={onClose}
      panel={panel}
      onPanel={onPanel}>
      {children}
    </ImapMessageActions>
  ) : (
    <GmailMessageActions
      id={id}
      view={folder ?? inboxFolder}
      markedRef={markedRef}
      onClose={onClose}
      panel={panel}
      onPanel={onPanel}>
      {children}
    </GmailMessageActions>
  );
}

// Saved mail remains readable and replyable while provider checks are unavailable.

// iPhone keeps one bottom capsule. The iPad frames set the top toolbar's organizing actions,
// responses and More apart in their own glass groups, 11.5pt apart as the Mac groups scaled 1.15,
// with Delete between Archive and Move.
function ToolbarGroups({
  archive,
  trash,
  folders,
  respond,
  more,
}: {
  readonly archive: (() => void) | undefined;
  readonly trash: Named | undefined;
  readonly folders: Parameters<typeof FoldersButton>[0]['folders'] | undefined;
  readonly respond: ReactNode;
  readonly more: ReactNode;
}) {
  const { t } = useLocalization();
  const organize = [
    archive === undefined ? null : (
      <ToolbarButton
        key="archive"
        icon="archivebox"
        label={t('gmailActions.label.archive')}
        onPress={archive}
      />
    ),
    // iPhone keeps Delete in its Reply sheet and More.
    compact || trash === undefined ? null : (
      <ToolbarButton
        key="trash"
        icon="trash"
        label={trash.label}
        onPress={() => {
          trash.run();
        }}
      />
    ),
    folders === undefined ? null : (
      <FoldersButton
        key="folders"
        folders={folders}
      />
    ),
  ];
  if (compact) {
    return (
      <GlassGroup
        wide
        pointerEvents="box-none">
        {organize}
        {respond}
        {more}
      </GlassGroup>
    );
  }
  return (
    <View
      pointerEvents="box-none"
      style={styles.groups}>
      {archive === undefined &&
      trash === undefined &&
      folders === undefined ? null : (
        <GlassGroup
          scaled
          pointerEvents="box-none">
          {organize}
        </GlassGroup>
      )}
      {respond === null ? null : (
        <GlassGroup
          scaled
          pointerEvents="box-none">
          {respond}
        </GlassGroup>
      )}
      {more === null ? null : (
        <GlassGroup
          scaled
          pointerEvents="box-none">
          {more}
        </GlassGroup>
      )}
    </View>
  );
}

// The toolbar's Move, which toggles its folders or labels. On iPad, Move's destinations open in a
// system popover on it, which closes on a tap outside and keeps itself clear of the keyboard.
function FoldersButton({
  folders,
}: {
  readonly folders: Readonly<{
    label: string;
    open: boolean;
    toggle: () => void;
    popover?: ReactElement;
    // The popover's surface where the frames draw one over the system's glass, as in Dark.
    background?: string;
  }>;
}) {
  const button = (
    <ToolbarButton
      icon="folder"
      label={folders.label}
      expanded={folders.open}
      onPress={() => {
        folders.toggle();
      }}
    />
  );
  return folders.popover === undefined ? (
    button
  ) : (
    <Host matchContents>
      <Popover
        isPresented={folders.open}
        onIsPresentedChange={(presented) => {
          if (!presented && folders.open) {
            folders.toggle();
          }
        }}>
        <Popover.Trigger>
          <RNHostView matchContents>{button}</RNHostView>
        </Popover.Trigger>
        <Popover.Content>
          <Group
            modifiers={
              folders.background === undefined
                ? []
                : [presentationBackground(folders.background)]
            }>
            <RNHostView matchContents>{folders.popover}</RNHostView>
          </Group>
        </Popover.Content>
      </Popover>
    </Host>
  );
}

export function MessageActionsNotice({ id }: { readonly id: string }) {
  const state = useInbox();
  const store = useInboxActions();
  const { t } = useLocalization();
  const provider = useProviderName();
  if (
    'openFolder' in store ||
    state.kind !== 'ready' ||
    !('sync' in state) ||
    !('resolvePending' in store) ||
    state.organize
  ) {
    return null;
  }
  const message = listedMessage(state, id);
  return message !== undefined && canOrganize(message) ? (
    <Notice
      icon="info.circle"
      message={t('gmailActions.savedOnly', { provider })}
    />
  ) : null;
}

// Mail in Spam goes back to the Inbox as Not Spam; from Trash it keeps Move to Inbox.
const returned = (name: string, spam: boolean) =>
  name === 'restore' && spam ? 'notSpam' : name;

// iPhone's Gmail labels to add or remove, which More's menu or the Reply sheet opens in a system
// sheet, as the #1683 frames draw. New Label… opens its own sheet once this one finishes
// dismissing, since a sibling sheet cannot present before then.
function LabelsSheet({
  open,
  renderLabels,
  onClose,
  onNewLabel,
}: {
  readonly open: boolean;
  readonly renderLabels: Labels;
  readonly onClose: () => void;
  readonly onNewLabel: () => void;
}) {
  const colors = usePalette();
  const appearance = useAppearance();
  const [creating, setCreating] = useState(false);
  return (
    <Host matchContents>
      <BottomSheet
        isPresented={open}
        onIsPresentedChange={(presented) => {
          if (!presented) {
            onClose();
          }
        }}
        onDismiss={() => {
          if (creating) {
            setCreating(false);
            onNewLabel();
          }
        }}>
        <Group
          modifiers={[
            presentationDetents(['medium', 'large']),
            // The Dark frames draw the sheet as the glass panel surface; Light keeps the system's
            // sheet glass, as the Reply sheet does.
            ...(appearance === 'dark'
              ? [presentationBackground(colors.surfacePanel)]
              : []),
          ]}>
          <RNHostView>
            {renderLabels(() => {
              setCreating(true);
              onClose();
            })}
          </RNHostView>
        </Group>
      </BottomSheet>
    </Host>
  );
}

// The More menu's titles and symbols, as the row menu names the same actions.
const menuActions = (t: ReturnType<typeof useLocalization>['t']) =>
  ({
    pin: [t('contextMenu.pin'), 'pin'],
    unpin: [t('contextMenu.unpin'), 'pin.slash'],
    read: [t('contextMenu.read'), 'envelope.open'],
    unread: [t('contextMenu.unread'), 'envelope.badge'],
    restore: [t('contextMenu.restore'), 'tray.and.arrow.down'],
    notSpam: [t('contextMenu.notSpam'), 'tray.and.arrow.down'],
    spam: [t('contextMenu.spam'), 'xmark.bin'],
    trash: [t('contextMenu.trash'), 'trash'],
  }) as const;

// More: the system menu the iPad frames draw: read state, Move to Spam (Not Spam in Spam) and
// Move to…, then Trash's Move to Inbox and Gmail's Labels, which open in their own sheet. The
// iPhone toolbar has no Delete or Pin, so its menu ends with Delete and starts with Pin.
function MoreButton({
  more,
  folders,
}: {
  readonly more: Readonly<{
    toggle: () => void;
    actions: readonly Named[];
    renderLabels?: Labels | undefined;
    // Unsubscribe… for a mailing list's message.
    unsubscribe?: readonly MenuItem[];
  }>;
  // Move's destinations, which open beneath the toolbar.
  readonly folders:
    | Readonly<{ show: Readonly<{ run: () => void }> }>
    | undefined;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const titled = menuActions(t);
  const items = (names: ReadonlyArray<keyof typeof titled>) =>
    names.flatMap((name) =>
      more.actions
        .filter((action) => action.name === name)
        .map(({ run }) => {
          const [title, symbol] = titled[name];
          return {
            key: name,
            title,
            symbol,
            destructive: name === 'trash',
            run,
          };
        }),
    );
  return (
    <MenuButton
      accessibilityLabel={t('message.more')}
      hitSlop={compact ? undefined : scaledToolbarSlop}
      sections={[
        {
          items: [
            ...items([
              ...(compact ? (['pin', 'unpin'] as const) : []),
              'read',
              'unread',
              'notSpam',
              'spam',
            ]),
            ...(folders === undefined
              ? []
              : [
                  {
                    key: 'move',
                    title: t('contextMenu.moveTo'),
                    symbol: 'folder',
                    run: folders.show.run,
                  },
                ]),
          ],
        },
        {
          items: [
            ...items(['restore']),
            ...(more.renderLabels === undefined
              ? []
              : [
                  {
                    key: 'labels',
                    title: t('gmailActions.labels'),
                    symbol: 'tag',
                    run: more.toggle,
                  },
                ]),
          ],
        },
        { items: more.unsubscribe ?? [] },
        ...(compact ? [{ items: items(['trash']) }] : []),
      ]}
      style={compact ? styles.compactMoreButton : styles.moreButton}>
      <SFSymbol
        name="ellipsis"
        size={compact ? 20 : scaledToolbar.symbol}
        color={colors.textPrimary}
      />
    </MenuButton>
  );
}

// The organizing actions the iPhone Reply sheet offers, in the design's order.
const threadActions = (
  t: ReturnType<typeof useLocalization>['t'],
  {
    archive,
    folders,
    more,
    onPanel,
  }: Pick<
    Parameters<typeof Toolbar>[0],
    'archive' | 'folders' | 'more' | 'onPanel'
  >,
): ThreadAction[] => [
  ...(archive === undefined
    ? []
    : [
        {
          name: 'archive',
          label: t('gmailActions.label.archive'),
          icon: 'archivebox.fill',
          group: 'tile' as const,
          run: archive,
        },
      ]),
  ...['pin', 'unpin', 'read', 'unread']
    .flatMap((name) => more.actions.filter((action) => action.name === name))
    .map(({ name, label, run }) => ({
      name,
      label,
      icon: actionIcons[name] ?? 'ellipsis',
      group: 'state' as const,
      run,
    })),
  ...(folders === undefined
    ? []
    : [
        {
          name: 'move',
          label: t('contextMenu.moveTo'),
          icon: 'folder',
          group: 'place' as const,
          run: folders.show.run,
        },
      ]),
  ...(more.renderLabels === undefined
    ? []
    : [
        {
          name: 'labels',
          label: t('gmailActions.labels'),
          icon: 'tag',
          group: 'place' as const,
          run: () => {
            onPanel('more');
          },
        },
      ]),
  // The sheet names its message actions as the reader's message menu does.
  ...['restore', 'notSpam', 'spam', 'trash']
    .flatMap((name) => more.actions.filter((action) => action.name === name))
    .map(({ name, label, run }) => ({
      name,
      label:
        new Map([
          ['notSpam', t('contextMenu.notSpam')],
          ['spam', t('contextMenu.spam')],
          ['trash', t('contextMenu.trash')],
        ]).get(name) ?? label,
      icon: actionIcons[name] ?? 'ellipsis',
      group: 'place' as const,
      run,
    })),
];

// The Command Palette's Pin or Unpin for the reader's message.
function PinCommand({ pin }: { readonly pin: PinAction | undefined }) {
  const { t } = useLocalization();
  if (pin === undefined) {
    return null;
  }
  return (
    <RegisterCommands
      offer={() =>
        organizeCommands(t, {
          target: pin.target,
          actions: [{ name: pin.name, label: pin.label, action: pin }],
          act: ({ run }) => {
            run();
          },
          destinations: [],
        })
      }
    />
  );
}

// iPhone's More lists Pin first.
const withPin = <More extends Readonly<{ actions: readonly Named[] }>>(
  more: More,
  pin: PinAction | undefined,
) =>
  compact && pin !== undefined
    ? { ...more, actions: [pin, ...more.actions] }
    : more;

// The toolbar's last group: Pin on iPad, then More, which mail with no organizing actions, such as
// saved mail without organizing permission, lacks.
const lastGroup = (
  pin: PinAction | undefined,
  more: Parameters<typeof MoreButton>[0]['more'],
  folders: Parameters<typeof MoreButton>[0]['folders'],
) => {
  const buttons = [
    compact || pin === undefined ? null : (
      <ToolbarButton
        key="pin"
        icon={actionIcons[pin.name] ?? 'pin'}
        label={pin.label}
        onPress={() => {
          pin.run();
        }}
      />
    ),
    more.actions.length === 0 &&
    more.renderLabels === undefined &&
    folders === undefined &&
    (more.unsubscribe ?? []).length === 0 ? null : (
      <MoreButton
        key="more"
        more={more}
        folders={folders}
      />
    ),
  ];
  return buttons.every((button) => button === null) ? null : buttons;
};

// The toolbar and the panel or sheet one of its buttons opened. iPad shows Pin first in the last
// group, before More; iPhone lists it in More and the Reply sheet, with the read state.
function Toolbar({
  id,
  archive,
  folders,
  more: organizing,
  pin,
  labeling,
  onPanel,
  children,
}: {
  // The reader's message, which More may offer to unsubscribe from.
  readonly id: string;
  readonly onPanel: PanelState['onPanel'];
  // The iPhone Labels sheet New Label… opened, which the reader's panel state also holds.
  readonly labeling?: boolean;
  readonly archive: (() => void) | undefined;
  readonly folders:
    | Readonly<
        {
          label: string;
          open: boolean;
          toggle: () => void;
          // The Reply sheet's entry, which opens the destinations even when they are shown.
          show: Readonly<{ label: string; run: () => void }>;
        } & (
          | { sheet: ReactNode }
          // Move's destinations, or iPad's Gmail labels, in the system popover on the toolbar's Move.
          | { popover: ReactElement; background?: string }
        )
      >
    | undefined;
  readonly more: Readonly<{
    open: boolean;
    toggle: () => void;
    // The actions More lists, which the iPhone Reply sheet offers instead.
    actions: readonly Named[];
    // Gmail's labels to add or remove, which More lists on iPhone, where Move is a picker. The
    // Reply sheet opens them in the same sheet.
    renderLabels?: Labels | undefined;
  }>;
  readonly pin?: PinAction | undefined;
  readonly children: ReactNode;
}) {
  const { t } = useLocalization();
  const more = {
    ...withPin(organizing, pin),
    unsubscribe: useUnsubscribeItems(id),
  };
  // The reader's open panel lasts only while this toolbar shows it. Closing it, Move or organizing
  // becoming unavailable, or the toolbar leaving clears it, so no dismissal stays behind.
  const shown = more.open || folders?.open === true || labeling === true;
  useEffect(() => {
    if (!shown) {
      return undefined;
    }
    return () => {
      onPanel(undefined);
    };
  }, [shown, onPanel]);
  // Mail that cannot be answered, such as IMAP mail, has no Reply sheet and keeps More.
  const [replySheet, setReplySheet] = useState(false);
  const thread = {
    offered: setReplySheet,
    actions: threadActions(t, { archive, folders, more, onPanel }),
  };
  return (
    <>
      <PinCommand pin={pin} />
      <View
        pointerEvents="box-none"
        style={styles.toolbar}>
        <ToolbarGroups
          archive={archive}
          trash={more.actions.find(({ name }) => name === 'trash')}
          folders={folders}
          respond={
            children === null || children === undefined ? null : (
              <ThreadActionsContext value={thread}>
                {children}
              </ThreadActionsContext>
            )
          }
          more={replySheet ? null : lastGroup(pin, more, folders)}
        />
      </View>
      {folders !== undefined && 'sheet' in folders ? folders.sheet : null}
      {more.renderLabels === undefined ? null : (
        <LabelsSheet
          open={more.open}
          renderLabels={more.renderLabels}
          onClose={() => {
            onPanel(undefined);
          }}
          onNewLabel={() => {
            onPanel('newLabel');
          }}
        />
      )}
    </>
  );
}

// The preview Inbox's read state, the one action its fixture can change.
function PreviewMessageActions({
  inbox,
  id,
  markedRef,
}: {
  readonly inbox: PersistentInbox;
  readonly id: string;
  readonly markedRef: Marked;
}) {
  const state = useInbox();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const message =
    state.kind === 'ready'
      ? state.messages.find((item) => item.id === id)
      : undefined;
  if (message === undefined) {
    return null;
  }
  const read = message.unread
    ? ({ name: 'read', label: t('message.markRead'), action: false } as const)
    : ({
        name: 'unread',
        label: t('message.markUnread'),
        action: true,
      } as const);
  const act = (unread: boolean) => {
    void inbox.setUnread(message.id, unread);
  };
  return (
    <>
      <ReadWhenOpened
        markedRef={markedRef}
        store={inbox}
        message={message}
        read={async ({ unread }) => {
          if (unread) {
            await inbox.setUnread(message.id, false);
          }
        }}
      />
      <RegisterCommands
        offer={() =>
          organizeCommands(t, {
            target: commandTarget(mailbox?.id, message),
            actions: [read],
            act,
            destinations: [],
          })
        }
      />
      <View style={styles.toolbar}>
        <GlassGroup scaled={!compact}>
          <ToolbarButton
            icon={read.name === 'read' ? 'envelope.open' : 'envelope.badge'}
            label={read.label}
            onPress={() => {
              act(read.action);
            }}
          />
        </GlassGroup>
      </View>
    </>
  );
}

// An IMAP message's read state, moves to the folders its server declares for archive, Trash and
// Spam, and Move to any other folder. A message that leaves its folder closes the reader.
function ImapMessageActions({
  inbox,
  id,
  markedRef,
  onClose,
  panel,
  onPanel: setPanel,
  children,
}: PanelState & {
  readonly inbox: ImapInbox;
  readonly id: string;
  readonly markedRef: Marked;
  readonly onClose?: (() => void) | undefined;
  readonly children: ReactNode;
}) {
  const state = useInbox();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const pinFor = usePinFor();
  const message = useSyncExternalStore(inbox.subscribe, () =>
    inbox.message(id),
  );
  if (state.kind !== 'ready' || !('imap' in state) || message === undefined) {
    return null;
  }
  const act = (action: ImapAction) => {
    void inbox.organize(message, action);
    if ('destination' in action) {
      onClose?.();
    }
  };
  const targets = imapMoveTargets(message, state);
  const actions = imapQuickActions(t, message, state);
  const archive = actions.find(({ name }) => name === 'archive');
  const toggle = (which: ReaderPanel) => {
    setPanel(panel === which ? undefined : which);
  };
  return (
    <>
      <ReadWhenOpened
        markedRef={markedRef}
        store={inbox}
        message={message}
        read={inbox.readOpened}
      />
      <RegisterCommands
        offer={() =>
          organizeCommands(t, {
            target: commandTarget(mailbox?.id, message),
            actions,
            act,
            destinations: targets.map(({ name }) => ({
              id: name,
              title: name === inboxFolder ? t('inbox.title') : name,
              icon: name === inboxFolder ? 'tray' : 'folder',
              run: () => {
                act({ kind: 'move', destination: name });
              },
            })),
          })
        }
      />
      <Toolbar
        id={id}
        onPanel={setPanel}
        pin={pinFor(message)}
        archive={
          archive === undefined
            ? undefined
            : () => {
                act(archive.action);
              }
        }
        folders={
          targets.length === 0
            ? undefined
            : {
                label: t(
                  panel === 'folders'
                    ? 'gmailActions.hideFolders'
                    : 'gmailActions.folders',
                ),
                open: panel === 'folders',
                toggle: () => {
                  toggle('folders');
                },
                show: {
                  label: t('gmailActions.folders'),
                  run: () => {
                    setPanel('folders');
                  },
                },
                ...placed(
                  <MovePicker
                    open={panel === 'folders'}
                    message={message}
                    destinations={state.folders.map(
                      ({ name, roles, selectable, delimiter }) => {
                        const path =
                          delimiter === undefined
                            ? [name]
                            : name.split(delimiter);
                        return {
                          id: name,
                          path: localizedPath(path, t('inbox.title')),
                          inboxPath: path[0] === inboxFolder,
                          icon: folderIcon(name, roles),
                          current: name === message.folder,
                          selectable,
                          count:
                            name === inboxFolder
                              ? inboxUnread(state.messages)
                              : undefined,
                        };
                      },
                    )}
                    limited={undefined}
                    onMove={(destination) => {
                      act({ kind: 'move', destination });
                    }}
                    onClose={() => {
                      setPanel(undefined);
                    }}
                  />,
                ),
              }
        }
        more={{
          open: panel === 'more',
          toggle: () => {
            toggle('more');
          },
          actions: actions
            .filter(({ name }) => name !== 'archive')
            .map(({ name, label, action }) => ({
              name: returned(
                name,
                state.folders.some(
                  ({ name: folder, roles }) =>
                    folder === message.folder && roles.includes('junk'),
                ),
              ),
              label,
              run: () => {
                act(action);
              },
            })),
        }}>
        {children}
      </Toolbar>
    </>
  );
}

// More with no actions, for mail that offers only responses and Pin.
const noMore = {
  open: false,
  toggle: () => undefined,
  actions: [],
} as const;

// Responses and Pin, for online results, also those the view does not list, and saved mail
// without organizing permission. Other mail the reader cannot find shows its responses alone.
function RespondAndPin({
  message,
  onPanel,
  children,
}: {
  readonly message: Parameters<ReturnType<typeof usePinFor>>[0] | undefined;
  readonly onPanel: PanelState['onPanel'];
  readonly children: ReactNode;
}) {
  const pinFor = usePinFor();
  if (message === undefined) {
    return <GlassGroup>{children}</GlassGroup>;
  }
  return (
    <Toolbar
      id={message.id}
      onPanel={onPanel}
      pin={pinFor(message)}
      archive={undefined}
      folders={undefined}
      more={noMore}>
      {children}
    </Toolbar>
  );
}

// The message the reader shows: the one its view lists, or an online result the view does not list.
const shownMessage = <Listed,>(
  state: Extract<ReturnType<typeof useInbox>, { kind: 'ready' }>,
  id: string,
  listed: Listed | undefined,
) =>
  listed ??
  ('found' in state ? state.found?.find((item) => item.id === id) : undefined);

// The Dark frames draw the labels' popover as the glass panel surface; Light keeps the system's
// popover glass, as the Reply sheet keeps its sheet glass.
const darkPanel = (appearance: string, surface: string) =>
  appearance === 'dark' ? { background: surface } : {};

// The Labels or Folders toggle. New Label… opens Labels, to create a Gmail label and apply it: an
// iPhone sheet above the toolbar, or on iPad the labels' own popover. While it shows, the toggle
// reads Hide Labels and closes it.
const labelsToggle = (panel: ReaderPanel | undefined, picker: boolean) => {
  const labeling = panel === 'newLabel';
  const shown = panel === 'folders' || labeling;
  const hide = picker ? 'gmailActions.hideFolders' : 'gmailActions.hideLabels';
  const show = picker ? 'gmailActions.folders' : 'gmailActions.labels';
  return {
    labeling,
    sheet: compact && labeling,
    open: panel === 'folders' || (!compact && labeling),
    next: shown ? undefined : 'folders',
    label: (picker ? panel === 'folders' : shown) ? hide : show,
  } as const;
};

// The reader's Gmail and Microsoft actions. A message that leaves the view it was chosen in, the
// Inbox or another Gmail view, closes the reader.
function GmailMessageActions({
  id,
  view: opened,
  markedRef,
  onClose,
  panel,
  onPanel: setPanel,
  children,
}: PanelState & {
  readonly id: string;
  readonly view: string;
  readonly markedRef: Marked;
  readonly onClose?: (() => void) | undefined;
  readonly children: ReactNode;
}) {
  const state = useInbox();
  const store = useInboxActions();
  const colors = usePalette();
  const appearance = useAppearance();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const pinFor = usePinFor();
  const provider = mailbox?.provider ?? 'gmail';
  // The reader holds the view it was opened in, so browsing other views cannot evict its message.
  useLayoutEffect(() => {
    if (opened === inboxFolder || !('retainView' in store)) {
      return undefined;
    }
    return store.retainView(opened);
  }, [store, opened]);
  if (
    state.kind !== 'ready' ||
    !('sync' in state) ||
    !('resolvePending' in store)
  ) {
    return null;
  }
  // A label or folder the provider removed falls back to the Inbox, as the list does.
  const view = gmailViewName(state, opened, provider);
  const message = viewMessage(state, id, view);
  if (message === undefined || !canOrganize(message) || !state.organize) {
    return (
      <RespondAndPin
        message={shownMessage(state, id, message)}
        onPanel={setPanel}>
        {children}
      </RespondAndPin>
    );
  }
  const act = (action: GmailAction) => {
    void store.organize(message, action);
    if (leavesView(view, message.labels ?? [], action)) {
      onClose?.();
    }
  };
  const applied = new Set(message.labels);
  // A Microsoft message is in one folder: it moves, but has no labels to add or remove.
  const folders = provider !== 'gmail';
  const actions = quickActions(t, message, {
    provider,
    unavailableActions: state.unavailableActions,
    view,
  });
  const archive = actions.find(({ name }) => name === 'archive');
  const toggle = (which: ReaderPanel) => {
    setPanel(panel === which ? undefined : which);
  };
  // iPhone moves through the shared picker, as Microsoft's folders always do.
  const picker = folders || compact;
  const labels = labelsToggle(panel, picker);
  const newLabel = (
    <NewLabel
      open={labels.labeling}
      labels={state.labels}
      onApply={(label) => {
        act(gmailAction.label(label));
        setPanel(undefined);
      }}
      onCreate={(name) => store.createLabel(message, name)}
      onClose={() => {
        setPanel(undefined);
      }}
    />
  );
  // Gmail's labels to add or remove, each with Move to unless the picker moves instead.
  const labelControls = (moves: boolean, createLabel: () => void) => (
    <LabelChoices
      labels={state.labels}
      applied={applied}
      notes={[
        ...(state.labels.length === 0 ? [t('gmailActions.noLabels')] : []),
        ...(state.labelsLimited === true
          ? [t('gmailActions.foldersLimited', { count: state.labels.length })]
          : []),
      ]}
      onToggle={(label, checked) => {
        act(checked ? gmailAction.unlabel(label) : gmailAction.label(label));
      }}
      onMove={
        moves
          ? (label) => {
              act(gmailAction.move(label, view, provider));
            }
          : undefined
      }
      onNewLabel={createLabel}
    />
  );
  return (
    <>
      <ReadWhenOpened
        markedRef={markedRef}
        store={store}
        message={message}
        read={store.readOpened}
      />
      <RegisterCommands
        offer={() =>
          organizeCommands(t, {
            target: commandTarget(mailbox?.id, message),
            actions,
            act,
            destinations: state.labels.map((label) => ({
              id: label.id,
              title: label.name,
              run: () => {
                act(gmailAction.move(label.id, view, provider));
              },
            })),
          })
        }
      />
      {/* Microsoft folders have no labels to create. */}
      {compact && !folders ? newLabel : null}
      <Toolbar
        id={id}
        onPanel={setPanel}
        labeling={labels.sheet}
        pin={pinFor(message)}
        archive={
          archive === undefined
            ? undefined
            : () => {
                act(archive.action);
              }
        }
        folders={{
          label: t(labels.label),
          open: labels.open,
          toggle: () => {
            setPanel(labels.next);
          },
          show: {
            label: t(picker ? 'gmailActions.folders' : 'gmailActions.labels'),
            run: () => {
              setPanel('folders');
            },
          },
          ...(picker
            ? placed(
                <MovePicker
                  open={panel === 'folders'}
                  message={message}
                  destinations={[
                    // Gmail and Graph list only custom move destinations; Inbox is display-only.
                    {
                      id: inboxFolder,
                      path: [t('inbox.title')],
                      inboxPath: true,
                      icon: 'tray',
                      current: applied.has(inboxFolder),
                      selectable: false,
                      count: inboxUnread(state.messages),
                    },
                    ...state.labels.map((label): Destination => {
                      // Graph names may contain slashes; only its listing knows the hierarchy.
                      const path =
                        label.path ??
                        (folders ? [label.name] : label.name.split('/'));
                      return {
                        id: label.id,
                        path:
                          label.inboxPath === true
                            ? [t('inbox.title'), ...path.slice(1)]
                            : path,
                        inboxPath: label.inboxPath === true,
                        icon: 'folder',
                        current: applied.has(label.id),
                        selectable: true,
                      };
                    }),
                  ]}
                  empty={t(
                    folders
                      ? 'gmailActions.noFolders'
                      : 'gmailActions.noLabels',
                  )}
                  limited={
                    state.labelsLimited === true
                      ? state.labels.length
                      : undefined
                  }
                  onMove={(destination) => {
                    act(gmailAction.move(destination, view, provider));
                  }}
                  onClose={() => {
                    setPanel(undefined);
                  }}
                />,
              )
            : {
                // New Label… takes the labels' place in the same popover.
                ...darkPanel(appearance, colors.surfacePanel),
                popover: labels.labeling
                  ? newLabel
                  : labelControls(true, () => {
                      setPanel('newLabel');
                    }),
              }),
        }}
        more={{
          open: panel === 'more',
          toggle: () => {
            toggle('more');
          },
          actions: actions
            .filter(({ name }) => name !== 'archive')
            .map(({ name, label, action }) => ({
              name: returned(name, view === 'SPAM'),
              label,
              run: () => {
                act(action);
              },
            })),
          renderLabels:
            picker && !folders
              ? (createLabel) => labelControls(false, createLabel)
              : undefined,
        }}>
        {children}
      </Toolbar>
    </>
  );
}
