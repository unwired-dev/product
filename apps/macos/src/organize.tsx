import type { Translate } from '@private-email/localization';
import type { MenuSection } from '@private-email/mail-core/context-menu';
import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';
import type {
  ImapAction,
  ImapInbox,
} from '@private-email/mail-core/imap-inbox';
import type { PersistentInbox } from '@private-email/mail-core/persistent-inbox';
import type { ReactNode, Ref } from 'react';

import {
  commandTarget,
  organizeCommands,
} from '@private-email/mail-core/commands';
import {
  canOrganize,
  gmailAction,
  gmailActionCopy,
  leavesView,
  quickActions,
  restoreAfter,
} from '@private-email/mail-core/gmail-actions';
import {
  listedMessage,
  viewMessage,
} from '@private-email/mail-core/gmail-inbox';
import {
  imapActionCopy,
  imapMoveTargets,
  imapQuickActions,
} from '@private-email/mail-core/imap-actions';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import { gmailViewName } from '@private-email/mail-core/mailboxes';
import { palette, radius, spacing } from '@private-email/mail-core/theme';
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  DynamicColorMacOS,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { RegisterCommands } from './command-palette.tsx';
import { PopUp } from './composer-controls.tsx';
import {
  askForText,
  askInSheet,
  GlassGroup,
  MenuButton,
  Notice,
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
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.s,
    marginBottom: spacing.xl,
  },
  toolbar: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  more: {
    minWidth: 32,
    minHeight: 28,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  button: {
    minHeight: 28,
    minWidth: 28,
    maxWidth: '100%',
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.m,
    borderWidth: 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.body, flexShrink: 1 },
  secondary: { ...textStyles.body },
  status: { paddingHorizontal: spacing.xl, paddingBottom: spacing.s },
});

// A keyboard-focusable control that shows where focus is.
function ActionButton({
  label,
  onPress,
}: {
  readonly label: string;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : colors.fillQuiet,
          borderColor: focused ? colors.accentInk : 'transparent',
        },
      ]}>
      <Text style={[styles.label, { color: colors.textPrimary }]}>{label}</Text>
    </Pressable>
  );
}

// The SF Symbol for each organizing action.
const icons: Readonly<Record<string, string>> = {
  read: 'envelope.open',
  unread: 'envelope.badge',
  star: 'flag',
  unstar: 'flag.fill',
  archive: 'archivebox',
  trash: 'trash',
  spam: 'xmark.bin',
  restore: 'tray.and.arrow.down',
};

// The reader's actions for the message's provider: glass groups of Archive, Delete and Move,
// the response actions passed as children, then the remaining actions.
export function MessageActions({
  id,
  folder,
  onClose,
  children,
}: {
  readonly id: string;
  // The Gmail view the message was chosen in, when not the Inbox.
  readonly folder?: string | undefined;
  readonly onClose?: (() => void) | undefined;
  readonly children?: ReactNode;
}) {
  const store = useInboxActions();
  if ('setUnread' in store) {
    return (
      <PreviewMessageActions
        id={id}
        inbox={store}
      />
    );
  }
  return 'openFolder' in store ? (
    <ImapMessageActions
      id={id}
      inbox={store}
      onClose={onClose}>
      {children}
    </ImapMessageActions>
  ) : (
    <GmailMessageActions
      id={id}
      view={folder ?? inboxFolder}
      onClose={onClose}>
      {children}
    </GmailMessageActions>
  );
}

// Saved mail remains readable and replyable while provider checks are unavailable.
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

type Named = Readonly<{ name: string; label: string; onPress: () => void }>;

// A provider's quick actions as toolbar buttons that run them.
const named = <Action,>(
  actions: ReadonlyArray<
    Readonly<{ name: string; label: string; action: Action }>
  >,
  act: (action: Action) => void,
): Named[] =>
  actions.map(({ name, label, action }) => ({
    name,
    label,
    onPress: () => {
      act(action);
    },
  }));

// The toolbar groups, with the Move control after Archive and Delete, and the More menu last.
function Toolbar({
  actions,
  move,
  more,
  children,
  ref,
}: {
  readonly actions: readonly Named[];
  readonly move?: ReactNode;
  readonly more: readonly MenuSection[];
  readonly children: ReactNode;
  // The view a sheet asked from the toolbar attaches to.
  readonly ref?: Ref<View>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const button = ({ name, label, onPress }: Named) => (
    <ToolbarButton
      key={name}
      icon={icons[name] ?? 'ellipsis'}
      label={label}
      onPress={onPress}
    />
  );
  const placing = actions.filter(
    ({ name }) => name === 'archive' || name === 'trash',
  );
  const rest = actions.filter(
    ({ name }) => name !== 'archive' && name !== 'trash',
  );
  return (
    <View
      ref={ref}
      collapsable={false}
      style={styles.toolbar}>
      {placing.length === 0 && move === undefined ? null : (
        <GlassGroup>
          {placing.map(button)}
          {move}
        </GlassGroup>
      )}
      {children}
      <GlassGroup>
        {rest.map(button)}
        <MenuButton
          accessibilityLabel={t('message.more')}
          sections={more}
          style={styles.more}>
          <SFSymbol
            name="ellipsis"
            size={16}
            color={colors.textPrimary}
          />
        </MenuButton>
      </GlassGroup>
    </View>
  );
}

type Folder = Readonly<{ id: string; name: string; symbol?: string }>;

// The More menu's items the design orders: Mark as Read or Unread, Move to and, for Gmail, Labels,
// each applied label checked, then New Label…. Keys carry the mailbox and message, so a late
// choice acts only on the message the menu opened for.
const moreMenu = (
  t: Translate,
  target: string,
  {
    actions,
    folders,
    onMove,
    labels,
  }: {
    readonly actions: readonly Named[];
    readonly folders: readonly Folder[];
    readonly onMove: (folder: string) => void;
    // Gmail's Labels submenu, in groups.
    readonly labels?: readonly MenuSection[] | undefined;
  },
): readonly MenuSection[] => [
  {
    items: [
      ...actions
        .filter(({ name }) => name === 'read' || name === 'unread')
        .map(({ name, onPress }) => ({
          key: `${target}\n${name}`,
          title: t(name === 'read' ? 'contextMenu.read' : 'contextMenu.unread'),
          symbol: icons[name] ?? 'envelope',
          run: onPress,
        })),
      ...(folders.length === 0
        ? []
        : [
            {
              title: t('contextMenu.moveTo'),
              symbol: 'folder',
              items: folders.map(({ id, name, symbol = 'folder' }) => ({
                key: `${target}\nmove\n${id}`,
                title: name,
                symbol,
                run: () => {
                  onMove(id);
                },
              })),
            },
          ]),
      ...(labels === undefined
        ? []
        : [
            {
              title: t('gmailActions.labels'),
              symbol: 'tag',
              sections: labels,
            },
          ]),
    ],
  },
];

// Move to a folder from the system menu dropped below the Move button; notes are disabled items.
// Keys carry the mailbox and message, so a late choice moves only the message the menu opened for.
function MoveMenu({
  target,
  folders,
  notes,
  onMove,
}: {
  // The mailbox and message, as their command target names them.
  readonly target: string;
  readonly folders: readonly Folder[];
  readonly notes?: readonly string[];
  readonly onMove: (folder: string) => void;
}) {
  const { t } = useLocalization();
  return (
    <PopUp
      icon="folder"
      accessibilityLabel={t('gmailActions.folders')}
      items={[
        ...folders.map(({ id, name, symbol = 'folder' }) => ({
          key: `${target}\n${id}`,
          title: name,
          accessibilityLabel: t('gmailActions.moveTo', { label: name }),
          symbol,
          run: () => {
            onMove(id);
          },
        })),
        ...(notes ?? []).map((note) => ({
          key: note,
          title: note,
          disabled: true,
          run: () => undefined,
        })),
      ]}
    />
  );
}

// The preview Inbox's read state, the one action its fixture can change.
function PreviewMessageActions({
  inbox,
  id,
}: {
  readonly inbox: PersistentInbox;
  readonly id: string;
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
        <GlassGroup>
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
  onClose,
  children,
}: {
  readonly inbox: ImapInbox;
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
  readonly children: ReactNode;
}) {
  const state = useInbox();
  const { t } = useLocalization();
  const mailbox = useMailbox();
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
  const folders = imapMoveTargets(message, state).map(({ name }) =>
    name === inboxFolder
      ? { id: name, name: t('inbox.title'), symbol: 'tray' }
      : { id: name, name },
  );
  const move = (destination: string) => {
    act({ kind: 'move', destination });
  };
  const actions = imapQuickActions(t, message, state);
  const buttons = named(actions, act);
  const target = commandTarget(mailbox?.id, message).id;
  return (
    <>
      <RegisterCommands
        offer={() =>
          organizeCommands(t, {
            target: commandTarget(mailbox?.id, message),
            actions,
            act,
            destinations: folders.map((folder) => ({
              id: folder.id,
              title: folder.name,
              icon: folder.symbol ?? 'folder',
              run: () => {
                move(folder.id);
              },
            })),
          })
        }
      />
      <Toolbar
        actions={buttons}
        move={
          folders.length === 0 ? undefined : (
            <MoveMenu
              target={target}
              folders={folders}
              onMove={move}
            />
          )
        }
        more={moreMenu(t, target, {
          actions: buttons,
          folders,
          onMove: move,
        })}>
        {children}
      </Toolbar>
    </>
  );
}

// The reader's Gmail and Microsoft actions. A message that leaves the view it was chosen in, the
// Inbox or another Gmail view, closes the reader.
function GmailMessageActions({
  id,
  view: opened,
  onClose,
  children,
}: {
  readonly id: string;
  readonly view: string;
  readonly onClose?: (() => void) | undefined;
  readonly children: ReactNode;
}) {
  const state = useInbox();
  const store = useInboxActions();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const provider = mailbox?.provider ?? 'gmail';
  const anchor = useRef<View>(null);
  const failure = useRef<ReturnType<typeof askInSheet>>(undefined);
  useEffect(
    () => () => {
      failure.current?.retire();
    },
    [],
  );
  // Keep the question's language so a preference change cannot replace its field.
  const [naming, setNaming] = useState<
    Readonly<{
      message: GmailMessage;
      t: Translate;
    }>
  >();
  // Asks for a name, then creates the label in Gmail and applies it; a failure is explained. The
  // sheet closes with the reader.
  useEffect(() => {
    if (naming === undefined || !('createLabel' in store)) {
      return undefined;
    }
    const { message, t: translate } = naming;
    const question = askForText(anchor.current, {
      title: translate('gmailActions.newLabelTitle'),
      detail: translate('gmailActions.newLabelDetail'),
      buttons: [translate('gmailActions.addLabel'), translate('common.cancel')],
      symbol: {
        name: 'tag',
        color: DynamicColorMacOS({
          light: palette.light.accentInk,
          dark: palette.dark.accentInk,
        }),
      },
      field: translate('gmailActions.labelName'),
    });
    let asking = true;
    const answer = async () => {
      const choice = await question.answer;
      if (!asking) {
        return;
      }
      setNaming(undefined);
      const name = choice?.index === 0 ? choice.text.trim() : '';
      if (name !== '' && !(await store.createLabel(message, name))) {
        failure.current?.retire();
        failure.current = askInSheet(anchor.current, {
          title: translate('gmailActions.labelNotCreated', { label: name }),
          detail: translate('gmailActions.labelNotCreatedDetail'),
          buttons: [translate('common.ok')],
        });
      }
    };
    void answer();
    return () => {
      asking = false;
      question.retire();
    };
  }, [naming, store]);
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
  // Responses also work for online results and saved mail without organizing permission.
  if (message === undefined || !canOrganize(message)) {
    return children;
  }
  if (!state.organize) {
    return <View style={styles.toolbar}>{children}</View>;
  }
  const act = (action: GmailAction) => {
    void store.organize(message, action);
    if (leavesView(view, message.labels ?? [], action)) {
      onClose?.();
    }
  };
  const applied = new Set(message.labels);
  const move = (folder: string) => {
    act(gmailAction.move(folder, view, provider));
  };
  const actions = quickActions(t, message, {
    provider,
    unavailableActions: state.unavailableActions,
    view,
  });
  const buttons = named(actions, act);
  const target = commandTarget(mailbox?.id, message).id;
  const limited =
    state.labelsLimited === true
      ? t('gmailActions.foldersLimited', { count: state.labels.length })
      : undefined;
  return (
    <>
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
                move(label.id);
              },
            })),
          })
        }
      />
      <Toolbar
        ref={anchor}
        actions={buttons}
        move={
          <MoveMenu
            target={target}
            folders={state.labels}
            notes={[
              ...(state.labels.length === 0
                ? [
                    t(
                      provider === 'gmail'
                        ? 'gmailActions.noLabels'
                        : 'gmailActions.noFolders',
                    ),
                  ]
                : []),
              ...(limited === undefined ? [] : [limited]),
            ]}
            onMove={move}
          />
        }
        // A Microsoft message is in one folder: it moves, but has no labels to add or remove.
        more={moreMenu(t, target, {
          actions: buttons,
          folders: state.labels,
          onMove: move,
          labels:
            provider === 'gmail'
              ? [
                  {
                    items: state.labels.map(({ id: label, name }) => ({
                      key: `${target}\nlabel\n${label}`,
                      title: name,
                      symbol: '',
                      checked: applied.has(label),
                      run: () => {
                        act(
                          applied.has(label)
                            ? gmailAction.unlabel(label)
                            : gmailAction.label(label),
                        );
                      },
                    })),
                  },
                  {
                    items: [
                      {
                        key: `${target}\nnewLabel`,
                        title: t('gmailActions.newLabel'),
                        symbol: '',
                        run: () => {
                          setNaming({
                            message,
                            t,
                          });
                        },
                      },
                    ],
                  },
                ]
              : undefined,
        })}>
        {children}
      </Toolbar>
    </>
  );
}

// Each notice object is announced once, whichever provider's store made it.
const announced = new WeakSet();

// The latest organizing outcome for the mailbox's provider, and changes that still wait for it.
export function OrganizeStatus() {
  const store = useInboxActions();
  return 'openFolder' in store ? (
    <ImapOrganizeStatus inbox={store} />
  ) : (
    <GmailOrganizeStatus />
  );
}

// An IMAP change's outcome, Undo while a move can still be reversed, and changes saved on this
// device while the server cannot be reached.
function ImapOrganizeStatus({ inbox }: { readonly inbox: ImapInbox }) {
  const state = useInbox();
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = useProviderName();
  const imap = state.kind === 'ready' && 'imap' in state ? state : undefined;
  const notice = imap?.notice;
  useEffect(() => {
    if (notice !== undefined && !announced.has(notice)) {
      announced.add(notice);
      AccessibilityInfo.announceForAccessibility(
        imapActionCopy(t, notice, provider),
      );
    }
  }, [notice, provider, t]);
  if (imap === undefined) {
    return null;
  }
  const waiting =
    imap.pending > 0 &&
    (imap.status === 'retry' || imap.status === 'authentication');
  return (
    <View style={styles.status}>
      {notice === undefined ? null : (
        <View
          accessible
          accessibilityLabel={imapActionCopy(t, notice, provider)}
          accessibilityRole={notice.kind === 'done' ? 'text' : 'alert'}>
          <Text style={[styles.secondary, { color: colors.textPrimary }]}>
            {imapActionCopy(t, notice, provider)}
          </Text>
        </View>
      )}
      {imap.undo ? (
        <View style={styles.bar}>
          <ActionButton
            label={t('gmailActions.undo')}
            onPress={() => {
              void inbox.undo();
            }}
          />
        </View>
      ) : null}
      {imap.blocked === undefined ? null : (
        <ActionButton
          label={t('gmailActions.discardChange')}
          onPress={() => {
            if (imap.blocked !== undefined) {
              void inbox.discardPending(imap.blocked);
            }
          }}
        />
      )}
      {waiting ? (
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('gmailActions.pending', { count: imap.pending, provider })}
        </Text>
      ) : null}
    </View>
  );
}

// A Gmail or Microsoft change's outcome, and changes that still wait for the provider.
function GmailOrganizeStatus() {
  const state = useInbox();
  const store = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = useProviderName();
  const notice =
    state.kind === 'ready' && 'sync' in state ? state.notice : undefined;
  // VoiceOver announces the outcome once, however many windows show it; the action that caused it
  // may have closed the reader.
  useEffect(() => {
    if (notice !== undefined && !announced.has(notice)) {
      announced.add(notice);
      AccessibilityInfo.announceForAccessibility(
        gmailActionCopy(t, notice, provider),
      );
    }
  }, [notice, provider, t]);
  if (
    state.kind !== 'ready' ||
    !('sync' in state) ||
    !('resolvePending' in store)
  ) {
    return null;
  }
  const undo =
    notice === undefined
      ? undefined
      : restoreAfter(notice.action, notice.message.labels);
  const waiting =
    state.pending > 0 &&
    (state.sync === 'retry' || state.sync === 'authentication');
  return (
    <View style={styles.status}>
      {notice === undefined ? null : (
        <View
          accessible
          accessibilityLabel={gmailActionCopy(t, notice, provider)}
          // Keep refusal semantics; the effect above owns the explicit announcement.
          accessibilityRole={notice.kind === 'done' ? 'text' : 'alert'}>
          <Text style={[styles.secondary, { color: colors.textPrimary }]}>
            {gmailActionCopy(t, notice, provider)}
          </Text>
        </View>
      )}
      {notice?.kind === 'done' && undo !== undefined ? (
        <View style={styles.bar}>
          <ActionButton
            label={t('gmailActions.undo')}
            onPress={() => {
              void store.organize(notice.message, undo);
            }}
          />
        </View>
      ) : null}
      {state.saving > 0 ? (
        <Text
          accessibilityRole="alert"
          style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('gmailActions.saving')}
        </Text>
      ) : null}
      {state.blockedAction === undefined ? null : (
        <>
          <Text
            accessibilityRole="alert"
            style={[styles.secondary, { color: colors.textSecondary }]}>
            {gmailActionCopy(
              t,
              { ...state.blockedAction, kind: 'blocked' },
              provider,
            )}
          </Text>
          <View style={styles.bar}>
            <ActionButton
              label={t('gmailActions.retryChange')}
              onPress={() => {
                void store.resolvePending('retry', state.blockedAction?.id);
              }}
            />
            <ActionButton
              label={t('gmailActions.discardChange')}
              onPress={() => {
                void store.resolvePending('discard', state.blockedAction?.id);
              }}
            />
          </View>
        </>
      )}
      {waiting ? (
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('gmailActions.pending', { count: state.pending, provider })}
        </Text>
      ) : null}
    </View>
  );
}
