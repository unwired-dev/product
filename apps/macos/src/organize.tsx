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

// The toolbar groups and the folder panel its Move button opened.
function Toolbar({
  actions,
  folders,
  children,
}: {
  readonly actions: readonly Named[];
  readonly folders:
    | Readonly<{
        label: string;
        open: boolean;
        toggle: () => void;
        panel: ReactNode;
      }>
    | undefined;
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
        {placing.length === 0 && folders === undefined ? null : (
          <GlassGroup>
            {placing.map(button)}
            {folders === undefined ? null : (
              <ToolbarButton
                icon="folder"
                label={folders.label}
                expanded={folders.open}
                onPress={() => {
                  folders.toggle();
                }}
              />
            )}
          </GlassGroup>
        )}
        {children}
        {rest.length === 0 ? null : <GlassGroup>{rest.map(button)}</GlassGroup>}
      </View>
      {folders === undefined ? null : (
        <View
          pointerEvents="box-none"
          style={styles.floatingPanels}>
          <GlassPanel open={folders.open}>{folders.panel}</GlassPanel>
        </View>
      )}
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
  const [moving, setMoving] = useState(false);
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
        actions={actions.map(({ name, label, action }) => ({
          name,
          label,
          onPress: () => {
            act(action);
          },
        }))}
        folders={
          targets.length === 0
            ? undefined
            : {
                label: t(
                  moving ? 'gmailActions.hideFolders' : 'gmailActions.folders',
                ),
                open: moving,
                toggle: () => {
                  setMoving(!moving);
                },
                panel: (
                  <ScrollView
                    style={styles.panels}
                    contentContainerStyle={styles.panel}>
                    {targets.map(({ name }) => (
                      <ActionButton
                        key={name}
                        label={t('gmailActions.moveTo', {
                          label: name === inboxFolder ? t('inbox.title') : name,
                        })}
                        onPress={() => {
                          act({ kind: 'move', destination: name });
                        }}
                      />
                    ))}
                  </ScrollView>
                ),
              }
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
  view,
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
    if (view === inboxFolder || !('retainView' in store)) {
      return undefined;
    }
    return store.retainView(view);
  }, [store, view]);
  if (
    state.kind !== 'ready' ||
    !('sync' in state) ||
    !('resolvePending' in store)
  ) {
    return null;
  }
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
  // A Microsoft message is in one folder: it moves, but has no labels to add or remove.
  const folders = provider !== 'gmail';
  const actions = quickActions(t, message, {
    provider,
    unavailableActions: state.unavailableActions,
    view,
  });
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
        actions={actions.map(({ name, label, action }) => ({
          name,
          label,
          onPress: () => {
            act(action);
          },
        }))}
        folders={{
          label: folders
            ? t(labeling ? 'gmailActions.hideFolders' : 'gmailActions.folders')
            : t(labeling ? 'gmailActions.hideLabels' : 'gmailActions.labels'),
          open: labeling,
          toggle: () => {
            setLabeling(!labeling);
          },
          panel: (
            <ScrollView
              style={styles.panels}
              contentContainerStyle={styles.panel}>
              {state.labels.length === 0 ? (
                <Text
                  style={[styles.secondary, { color: colors.textSecondary }]}>
                  {t(
                    folders
                      ? 'gmailActions.noFolders'
                      : 'gmailActions.noLabels',
                  )}
                </Text>
              ) : null}
              {state.labelsLimited === true ? (
                <Text
                  style={[styles.secondary, { color: colors.textSecondary }]}>
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
                  <ActionButton
                    label={t('gmailActions.moveTo', { label: label.name })}
                    onPress={() => {
                      act(gmailAction.move(label.id, view));
                    }}
                  />
                </View>
              ))}
            </ScrollView>
          ),
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
