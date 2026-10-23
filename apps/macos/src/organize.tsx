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
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  useEffect,
  useLayoutEffect,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { RegisterCommands } from './command-palette.tsx';
import { PopUp } from './composer-controls.tsx';
import {
  GlassGroup,
  GlassPanel,
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
  panels: { maxHeight: 280, flexGrow: 0 },
  floatingPanels: {
    position: 'absolute',
    top: 36 + spacing.m,
    right: spacing.l,
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
  panel: { gap: 4, padding: spacing.l },
  labelRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  labelName: { flexGrow: 1, flexShrink: 1, minWidth: 28 },
  secondary: { ...textStyles.body },
  status: { paddingHorizontal: spacing.xl, paddingBottom: spacing.s },
});

// A keyboard-focusable control that shows where focus is; a checked state makes it a checkbox.
function ActionButton({
  label,
  onPress,
  checked,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly checked?: boolean;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole={checked === undefined ? 'button' : 'checkbox'}
      accessibilityState={checked === undefined ? undefined : { checked }}
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
      {checked === true ? (
        <SFSymbol
          name="checkmark"
          color={colors.textPrimary}
        />
      ) : null}
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

// The toolbar groups, with the Move control after Archive and Delete, and the label panel the
// Gmail Labels button opened.
function Toolbar({
  actions,
  move,
  panel,
  children,
}: {
  readonly actions: readonly Named[];
  readonly move?: ReactNode;
  readonly panel?: ReactNode;
  readonly children: ReactNode;
}) {
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
    <>
      <View style={styles.toolbar}>
        {placing.length === 0 && move === undefined ? null : (
          <GlassGroup>
            {placing.map(button)}
            {move}
          </GlassGroup>
        )}
        {children}
        {rest.length === 0 ? null : <GlassGroup>{rest.map(button)}</GlassGroup>}
      </View>
      {panel === undefined ? null : (
        <View
          pointerEvents="box-none"
          style={styles.floatingPanels}>
          {panel}
        </View>
      )}
    </>
  );
}

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
  readonly folders: ReadonlyArray<
    Readonly<{ id: string; name: string; symbol?: string }>
  >;
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
        actions={actions.map(({ name, label, action }) => ({
          name,
          label,
          onPress: () => {
            act(action);
          },
        }))}
        move={
          folders.length === 0 ? undefined : (
            <MoveMenu
              target={commandTarget(mailbox?.id, message).id}
              folders={folders}
              onMove={move}
            />
          )
        }>
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
  const colors = usePalette();
  const { t } = useLocalization();
  const [labeling, setLabeling] = useState(false);
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
    act(gmailAction.move(folder, view));
  };
  const actions = quickActions(t, message, {
    provider,
    unavailableActions: state.unavailableActions,
    view,
  });
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
        actions={actions.map(({ name, label, action }) => ({
          name,
          label,
          onPress: () => {
            act(action);
          },
        }))}
        // A Microsoft message is in one folder: it moves, but has no labels to add or remove.
        move={
          provider === 'gmail' ? (
            <ToolbarButton
              icon="folder"
              label={t(
                labeling ? 'gmailActions.hideLabels' : 'gmailActions.labels',
              )}
              expanded={labeling}
              onPress={() => {
                setLabeling(!labeling);
              }}
            />
          ) : (
            <MoveMenu
              target={commandTarget(mailbox?.id, message).id}
              folders={state.labels}
              notes={[
                ...(state.labels.length === 0
                  ? [t('gmailActions.noFolders')]
                  : []),
                ...(limited === undefined ? [] : [limited]),
              ]}
              onMove={move}
            />
          )
        }
        panel={
          provider === 'gmail' ? (
            <GlassPanel open={labeling}>
              <ScrollView
                style={styles.panels}
                contentContainerStyle={styles.panel}>
                {state.labels.length === 0 ? (
                  <Text
                    style={[styles.secondary, { color: colors.textSecondary }]}>
                    {t('gmailActions.noLabels')}
                  </Text>
                ) : null}
                {limited === undefined ? null : (
                  <Text
                    style={[styles.secondary, { color: colors.textSecondary }]}>
                    {limited}
                  </Text>
                )}
                {state.labels.map((label) => (
                  <View
                    key={label.id}
                    style={styles.labelRow}>
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
                    <ActionButton
                      label={t('gmailActions.moveTo', { label: label.name })}
                      onPress={() => {
                        move(label.id);
                      }}
                    />
                  </View>
                ))}
              </ScrollView>
            </GlassPanel>
          ) : undefined
        }>
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
