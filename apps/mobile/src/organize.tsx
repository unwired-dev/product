import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type {
  ImapAction,
  ImapInbox,
} from '@private-email/mail-core/imap-inbox';
import type { PersistentInbox } from '@private-email/mail-core/persistent-inbox';
import type { ReactNode } from 'react';

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
import { spacing } from '@private-email/mail-core/theme';
import {
  useEffect,
  useLayoutEffect,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { Destination } from './move-sheet.tsx';

import { RegisterCommands } from './command-palette.tsx';
import { GlassGroup, GlassPanel, Notice, ToolbarButton } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  useInbox,
  useInboxActions,
  useMailbox,
  useProviderName,
} from './mailbox.tsx';
import { MoveSheet } from './move-sheet.tsx';
import { ActionButton } from './organize-action-button.tsx';
import { ThreadActionsContext } from './reply-sheet.tsx';
import { textStyles, usePalette } from './theme.ts';

const compact = Platform.OS === 'ios' && !Platform.isPad;

// The toolbar panel a reader shows: the folders or labels to move to, or More's remaining actions.
export type ReaderPanel = 'folders' | 'more';

// At most one panel is open. The reader holds which, so a tap outside the panel can close it.
type PanelState = Readonly<{
  panel: ReaderPanel | undefined;
  onPanel: (panel: ReaderPanel | undefined) => void;
}>;

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.s,
    marginBottom: spacing.xl,
  },
  toolbar: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  // Panels open above a bottom toolbar and below a top one; the reader positions the whole.
  panels: { maxHeight: 280, flexGrow: 0 },
  floatingPanels: {
    position: 'absolute',
    top: 52 + spacing.m,
    right: spacing.l,
    gap: spacing.s,
  },
  panel: { gap: 4, padding: spacing.l },
  labelRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  labelName: { flexGrow: 1, flexShrink: 1, minWidth: 44 },
  secondary: { ...textStyles.subheadline },
  status: { paddingHorizontal: spacing.xl, paddingBottom: spacing.s },
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
  star: 'star',
  unstar: 'star.slash',
  spam: 'xmark.bin',
  trash: 'trash',
  restore: 'tray.and.arrow.down',
};
type Named = Readonly<{ name: string; label: string; run: () => void }>;

const folderIcon = (name: string, roles: readonly string[]) => {
  if (name === inboxFolder) {
    return 'tray';
  }
  const role = roles.find((declared) => declared in roleIcons);
  return role === undefined ? 'folder' : (roleIcons[role] ?? 'folder');
};

// The Inbox's unread mail this device holds, as the mailbox list counts it; none shows no count.
const inboxUnread = (messages: ReadonlyArray<Readonly<{ unread: boolean }>>) =>
  messages.filter(({ unread }) => unread).length || undefined;

// The reader's actions for the message's provider: one glass toolbar of Archive, Move, the
// response actions passed as children, and More, whose panel lists the remaining actions.
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
      onClose={onClose}
      panel={panel}
      onPanel={onPanel}>
      {children}
    </ImapMessageActions>
  ) : (
    <GmailMessageActions
      id={id}
      view={folder ?? inboxFolder}
      onClose={onClose}
      panel={panel}
      onPanel={onPanel}>
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

// The toolbar and the panel or sheet one of its buttons opened.
function Toolbar({
  archive,
  folders,
  more,
  onPanel,
  children,
}: {
  readonly onPanel: PanelState['onPanel'];
  readonly archive: (() => void) | undefined;
  readonly folders:
    | Readonly<
        {
          label: string;
          open: boolean;
          // Where the button was pressed, so a sheet can grow out of it.
          toggle: (origin: number) => void;
          // The Reply sheet's entry, which opens the destinations even when they are shown.
          show: Readonly<{ label: string; run: (origin: number) => void }>;
        } & ({ panel: ReactNode } | { sheet: ReactNode })
      >
    | undefined;
  readonly more: Readonly<{
    open: boolean;
    toggle: () => void;
    // The actions More lists, which the iPhone Reply sheet also offers.
    actions: readonly Named[];
    // Gmail's labels to add or remove, which More lists on iPhone, where Move is a picker.
    labels?: ReactNode;
  }>;
  readonly children: ReactNode;
}) {
  const { t } = useLocalization();
  // The reader's open panel lasts only while this toolbar shows it. Closing it, Move or organizing
  // becoming unavailable, or the toolbar leaving clears it, so no dismissal stays behind.
  const shown = more.open || folders?.open === true;
  useEffect(() => {
    if (!shown) {
      return undefined;
    }
    return () => {
      onPanel(undefined);
    };
  }, [shown, onPanel]);
  const [shownPanel, setShownPanel] = useState<ReaderPanel>('more');
  const thread = {
    actions: [
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
      ...['star', 'unstar', 'read', 'unread']
        .flatMap((name) =>
          more.actions.filter((action) => action.name === name),
        )
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
              label: folders.show.label,
              icon: 'folder',
              group: 'place' as const,
              run: folders.show.run,
            },
          ]),
      ...['restore', 'spam', 'trash']
        .flatMap((name) =>
          more.actions.filter((action) => action.name === name),
        )
        .map(({ name, label, run }) => ({
          name,
          label,
          icon: actionIcons[name] ?? 'ellipsis',
          group: 'place' as const,
          run,
        })),
    ],
  };
  const foldersOpen =
    folders !== undefined && 'panel' in folders && folders.open;
  if (foldersOpen && shownPanel !== 'folders') {
    setShownPanel('folders');
  } else if (more.open && shownPanel !== 'more') {
    setShownPanel('more');
  }
  return (
    <>
      <View
        pointerEvents="box-none"
        style={styles.toolbar}>
        <GlassGroup pointerEvents="box-none">
          {archive === undefined ? null : (
            <ToolbarButton
              icon="archivebox"
              label={t('gmailActions.label.archive')}
              onPress={archive}
            />
          )}
          {folders === undefined ? null : (
            <ToolbarButton
              icon="folder"
              label={folders.label}
              expanded={folders.open}
              onPress={(event) => {
                folders.toggle(event.nativeEvent.pageX);
              }}
            />
          )}
          <ThreadActionsContext value={thread}>{children}</ThreadActionsContext>
          <ToolbarButton
            icon="ellipsis"
            label={t('message.more')}
            expanded={more.open}
            onPress={() => {
              more.toggle();
            }}
          />
        </GlassGroup>
      </View>
      {folders !== undefined && 'sheet' in folders ? folders.sheet : null}
      <View
        pointerEvents="box-none"
        testID="reader-panels"
        style={compact ? undefined : styles.floatingPanels}>
        <GlassPanel open={foldersOpen || more.open}>
          {shownPanel === 'folders' &&
          folders !== undefined &&
          'panel' in folders ? (
            folders.panel
          ) : (
            <ScrollView style={styles.panels}>
              <View style={styles.panel}>
                {more.actions.map(({ name, label, run }) => (
                  <ActionButton
                    key={name}
                    label={label}
                    onPress={run}
                  />
                ))}
                {more.labels}
              </View>
            </ScrollView>
          )}
        </GlassPanel>
      </View>
    </>
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
  panel,
  onPanel: setPanel,
  children,
}: PanelState & {
  readonly inbox: ImapInbox;
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
  readonly children: ReactNode;
}) {
  const state = useInbox();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const [origin, setOrigin] = useState(0);
  const message = useSyncExternalStore(inbox.subscribe, () =>
    inbox.message(id),
  );
  if (state.kind !== 'ready' || !('imap' in state) || message === undefined) {
    return null;
  }
  const act = (action: ImapAction) => {
    void inbox.organize(message, action);
    if (action.kind !== 'read' && action.kind !== 'unread') {
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
        onPanel={setPanel}
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
                toggle: (x) => {
                  setOrigin(x);
                  toggle('folders');
                },
                show: {
                  label: t('gmailActions.folders'),
                  run: (x) => {
                    setOrigin(x);
                    setPanel('folders');
                  },
                },
                ...(compact
                  ? {
                      sheet: (
                        <MoveSheet
                          open={panel === 'folders'}
                          origin={origin}
                          message={message}
                          destinations={state.folders.map(
                            ({ name, roles, selectable, delimiter }) => {
                              const path =
                                delimiter === undefined
                                  ? [name]
                                  : name.split(delimiter);
                              // The Inbox and folders nested in it show its localized name.
                              return {
                                id: name,
                                path: path.map((part, index) =>
                                  index === 0 && part === inboxFolder
                                    ? t('inbox.title')
                                    : part,
                                ),
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
                        />
                      ),
                    }
                  : {
                      panel: (
                        <ScrollView style={styles.panels}>
                          <View style={styles.panel}>
                            {targets.map(({ name }) => (
                              <ActionButton
                                key={name}
                                label={t('gmailActions.moveTo', {
                                  label:
                                    name === inboxFolder
                                      ? t('inbox.title')
                                      : name,
                                })}
                                onPress={() => {
                                  act({ kind: 'move', destination: name });
                                }}
                              />
                            ))}
                          </View>
                        </ScrollView>
                      ),
                    }),
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
              name,
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

// The reader's Gmail and Microsoft actions. A message that leaves the view it was chosen in, the
// Inbox or another Gmail view, closes the reader.
function GmailMessageActions({
  id,
  view: opened,
  onClose,
  panel,
  onPanel: setPanel,
  children,
}: PanelState & {
  readonly id: string;
  readonly view: string;
  readonly onClose?: (() => void) | undefined;
  readonly children: ReactNode;
}) {
  const state = useInbox();
  const store = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const [origin, setOrigin] = useState(0);
  const mailbox = useMailbox();
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
  // A label Gmail removed falls back to the Inbox, as the list does.
  const view = gmailViewName(state, opened);
  const message = viewMessage(state, id, view);
  // Responses also work for online results and saved mail without organizing permission.
  if (message === undefined || !canOrganize(message)) {
    return <GlassGroup>{children}</GlassGroup>;
  }
  if (!state.organize) {
    return (
      <View style={styles.toolbar}>
        <GlassGroup>{children}</GlassGroup>
      </View>
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
  // Labels to add or remove, each with Move to unless the picker moves instead.
  const labelControls = (moves: boolean) => (
    <>
      {state.labels.length === 0 ? (
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t(folders ? 'gmailActions.noFolders' : 'gmailActions.noLabels')}
        </Text>
      ) : null}
      {state.labelsLimited === true ? (
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('gmailActions.foldersLimited', {
            count: state.labels.length,
          })}
        </Text>
      ) : null}
      {state.labels.map((label) => (
        <View
          key={label.id}
          style={styles.labelRow}>
          {folders ? null : (
            <View style={styles.labelName}>
              <ActionButton
                checked={applied.has(label.id)}
                label={label.name}
                onPress={() => {
                  act(
                    applied.has(label.id)
                      ? gmailAction.unlabel(label.id)
                      : gmailAction.label(label.id),
                  );
                }}
              />
            </View>
          )}
          {moves ? (
            <ActionButton
              label={t('gmailActions.moveTo', { label: label.name })}
              onPress={() => {
                act(gmailAction.move(label.id, view));
              }}
            />
          ) : null}
        </View>
      ))}
    </>
  );
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
                act(gmailAction.move(label.id, view));
              },
            })),
          })
        }
      />
      <Toolbar
        onPanel={setPanel}
        archive={
          archive === undefined
            ? undefined
            : () => {
                act(archive.action);
              }
        }
        folders={{
          label: picker
            ? t(
                panel === 'folders'
                  ? 'gmailActions.hideFolders'
                  : 'gmailActions.folders',
              )
            : t(
                panel === 'folders'
                  ? 'gmailActions.hideLabels'
                  : 'gmailActions.labels',
              ),
          open: panel === 'folders',
          toggle: (x) => {
            setOrigin(x);
            toggle('folders');
          },
          show: {
            label: t(picker ? 'gmailActions.folders' : 'gmailActions.labels'),
            run: (x) => {
              setOrigin(x);
              setPanel('folders');
            },
          },
          ...(compact
            ? {
                sheet: (
                  <MoveSheet
                    open={panel === 'folders'}
                    origin={origin}
                    message={message}
                    destinations={[
                      // Gmail and Graph list only custom move destinations; Inbox is display-only.
                      {
                        id: inboxFolder,
                        path: [t('inbox.title')],
                        icon: 'tray',
                        current: applied.has(inboxFolder),
                        selectable: false,
                        count: inboxUnread(state.messages),
                      },
                      ...state.labels.map((label): Destination => ({
                        id: label.id,
                        // Graph names may contain slashes; only its listing knows the hierarchy.
                        path:
                          label.path ??
                          (folders ? [label.name] : label.name.split('/')),
                        icon: 'folder',
                        current: applied.has(label.id),
                        selectable: true,
                      })),
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
                      act(gmailAction.move(destination, view));
                    }}
                    onClose={() => {
                      setPanel(undefined);
                    }}
                  />
                ),
              }
            : {
                panel: (
                  <ScrollView style={styles.panels}>
                    <View style={styles.panel}>{labelControls(true)}</View>
                  </ScrollView>
                ),
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
              name,
              label,
              run: () => {
                act(action);
              },
            })),
          labels:
            picker && !folders ? (
              <>
                <Text
                  accessibilityRole="header"
                  style={[styles.secondary, { color: colors.textSecondary }]}>
                  {t('gmailActions.labels')}
                </Text>
                {labelControls(false)}
              </>
            ) : undefined,
        }}>
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
        <Text
          accessibilityRole={notice.kind === 'done' ? 'text' : 'alert'}
          style={[styles.secondary, { color: colors.textPrimary }]}>
          {imapActionCopy(t, notice, provider)}
        </Text>
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
        // Keep refusal semantics; the effect above owns the explicit announcement.
        <Text
          accessibilityRole={notice.kind === 'done' ? 'text' : 'alert'}
          style={[styles.secondary, { color: colors.textPrimary }]}>
          {gmailActionCopy(t, notice, provider)}
        </Text>
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
