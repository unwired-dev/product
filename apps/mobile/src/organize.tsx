import type { Translate } from '@private-email/localization';
import type { Message } from '@private-email/mail-core';
import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';
import type {
  ImapAction,
  ImapInbox,
  ImapMessage,
} from '@private-email/mail-core/imap-inbox';

import {
  canOrganize,
  gmailAction,
  gmailActionCopy,
  restoreAfter,
  quickActions,
} from '@private-email/mail-core/gmail-actions';
import {
  imapActionCopy,
  imapMoveTargets,
  imapQuickActions,
} from '@private-email/mail-core/imap-actions';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import { spacing } from '@private-email/mail-core/theme';
import { useEffect, useState, useSyncExternalStore } from 'react';
import {
  AccessibilityInfo,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { InboxMailbox } from './private-storage.ts';

import { Commands } from './command-palette.tsx';
import { useLocalization } from './localization.ts';
import {
  useInbox,
  useInboxActions,
  useMailbox,
  useProviderName,
} from './mailbox.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.small,
    marginBottom: spacing.large,
  },
  button: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: 12,
    borderWidth: 2,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
  label: { fontSize: 15 },
  panel: { gap: 4, marginBottom: spacing.large },
  labelRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.small },
  labelName: { flex: 1 },
  secondary: { fontSize: 14, lineHeight: 21 },
  status: { paddingHorizontal: spacing.large, paddingBottom: spacing.small },
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
          backgroundColor: pressed ? colors.selected : colors.sidebar,
          borderColor: focused ? colors.accent : 'transparent',
        },
      ]}>
      <Text style={[styles.label, { color: colors.accent }]}>
        {checked === true ? `✓ ${label}` : label}
      </Text>
    </Pressable>
  );
}

// A row's organizing action at its provider.
export type RowAction = Readonly<{
  name: string;
  label: string;
  run: () => void;
}>;

// A listed message's actions; a move notifies the list to close its selected reader.
export function rowActions({
  t,
  mailbox,
  message,
  onLeave,
}: {
  readonly t: Translate;
  readonly mailbox: InboxMailbox;
  readonly message: Message | GmailMessage | ImapMessage;
  readonly onLeave: () => void;
}): readonly RowAction[] {
  const { state, inbox } = mailbox;
  if (state.kind !== 'ready') {
    return [];
  }
  if (
    'openFolder' in inbox &&
    'receiveOnly' in state &&
    'folder' in message
  ) {
    return imapQuickActions(t, message, state).map(
      ({ name, label, action }) => ({
        name,
        label,
        run: () => {
          if (action.kind !== 'read' && action.kind !== 'unread') {
            onLeave();
          }
          void inbox.organize(message, action);
        },
      }),
    );
  }
  if (
    'resolvePending' in inbox &&
    'organize' in state &&
    state.organize &&
    'threadId' in message
  ) {
    return quickActions(t, message, {
      provider: mailbox.provider ?? 'gmail',
      unavailableActions: state.unavailableActions,
    }).map(({ name, label, action }) => ({
      name,
      label,
      run: () => {
        if (restoreAfter(action) !== undefined) {
          onLeave();
        }
        void inbox.organize(message, action);
      },
    }));
  }
  return [];
}

// The reader's actions for the message's provider.
export function MessageActions({
  id,
  onClose,
}: {
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
}) {
  const store = useInboxActions();
  return 'openFolder' in store ? (
    <ImapMessageActions
      id={id}
      inbox={store}
      onClose={onClose}
    />
  ) : (
    <GmailMessageActions
      id={id}
      onClose={onClose}
    />
  );
}

// An IMAP message's read state, moves to the folders its server declares for archive, Trash and
// Spam, and Move to any other folder. A message that leaves its folder closes the reader.
function ImapMessageActions({
  inbox,
  id,
  onClose,
}: {
  readonly inbox: ImapInbox;
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
}) {
  const state = useInbox();
  const mailbox = useMailbox();
  const { t } = useLocalization();
  const [moving, setMoving] = useState(false);
  const message = useSyncExternalStore(inbox.subscribe, () =>
    inbox.message(id),
  );
  if (
    state.kind !== 'ready' ||
    !('receiveOnly' in state) ||
    message === undefined
  ) {
    return null;
  }
  const act = (action: ImapAction) => {
    void inbox.organize(message, action);
    if (action.kind !== 'read' && action.kind !== 'unread') {
      onClose?.();
    }
  };
  const actions = imapQuickActions(t, message, state);
  const targets = imapMoveTargets(message, state);
  return (
    <>
      <Commands
        commands={[
          ...actions.map(({ name, label, action }) => ({
            id: name,
            label,
            keywords:
              name === 'archive'
                ? t('commandPalette.archiveKeywords')
                : name === 'read' || name === 'unread'
                  ? t('commandPalette.readKeywords')
                  : '',
            group: 'selection' as const,
            target: `${mailbox?.id}/${id}`,
            onRun: () => {
              act(action);
            },
          })),
          {
            id: 'move',
            label: t('commandPalette.move'),
            keywords: t('commandPalette.moveKeywords'),
            group: 'selection',
            target: `${mailbox?.id}/${id}`,
            disabled:
              targets.length === 0
                ? t('commandPalette.unsupported')
                : undefined,
            choices: targets.map(({ name }) => ({
              id: name,
              label: name === inboxFolder ? t('inbox.title') : name,
              group: 'selection' as const,
              target: `${mailbox?.id}/${id}`,
              onRun: () => {
                act({ kind: 'move', destination: name });
              },
            })),
          },
        ]}
      />
      <View style={styles.bar}>
        {actions.map(({ name, label, action }) => (
          <ActionButton
            key={name}
            label={label}
            onPress={() => {
              act(action);
            }}
          />
        ))}
        {targets.length === 0 ? null : (
          <ActionButton
            label={t(
              moving ? 'gmailActions.hideFolders' : 'gmailActions.folders',
            )}
            onPress={() => {
              setMoving(!moving);
            }}
          />
        )}
      </View>
      {moving && targets.length > 0 ? (
        <View style={styles.panel}>
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
        </View>
      ) : null}
    </>
  );
}

// The reader's Gmail and Microsoft actions. A message that leaves the Inbox closes the reader.
function GmailMessageActions({
  id,
  onClose,
}: {
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
}) {
  const state = useInbox();
  const mailbox = useMailbox();
  const store = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const [labeling, setLabeling] = useState(false);
  const provider = mailbox?.provider ?? 'gmail';
  const providerName = useProviderName();
  if (
    state.kind !== 'ready' ||
    !('sync' in state) ||
    !('resolvePending' in store)
  ) {
    return null;
  }
  const message = state.messages.find((item) => item.id === id);
  if (message === undefined || !canOrganize(message)) {
    return null;
  }
  if (!state.organize) {
    return (
      <Text style={[styles.secondary, { color: colors.secondary }]}>
        {t('gmailActions.savedOnly', { provider: providerName })}
      </Text>
    );
  }
  const act = (action: GmailAction) => {
    void store.organize(message, action);
    if (restoreAfter(action) !== undefined) {
      onClose?.();
    }
  };
  const applied = new Set(message.labels);
  const actions = quickActions(t, message, { provider }).map((action) => ({
    ...action,
    disabled: state.unavailableActions?.includes(action.name)
      ? t('commandPalette.unsupported')
      : undefined,
  }));
  const keywords = {
    archive: t('commandPalette.archiveKeywords'),
    read: t('commandPalette.readKeywords'),
    unread: t('commandPalette.readKeywords'),
    star: '',
    unstar: '',
    trash: '',
    spam: '',
  };
  // A Microsoft message is in one folder: it moves, but has no labels to add or remove.
  const folders = provider !== 'gmail';
  return (
    <>
      <Commands
        commands={[
          ...actions.map(({ name, label, action, disabled }) => ({
            id: name,
            label,
            keywords: keywords[name],
            disabled,
            group: 'selection' as const,
            target: `${mailbox?.id}/${id}`,
            onRun: () => {
              act(action);
            },
          })),
          {
            id: 'move',
            label: t('commandPalette.move'),
            keywords: t('commandPalette.moveKeywords'),
            group: 'selection',
            target: `${mailbox?.id}/${id}`,
            disabled:
              state.labels.length === 0
                ? t(
                    folders
                      ? 'gmailActions.noFolders'
                      : 'gmailActions.noLabels',
                  )
                : undefined,
            choices: state.labels.map((label) => ({
              id: label.id,
              label: label.name,
              group: 'selection' as const,
              target: `${mailbox?.id}/${id}`,
              onRun: () => {
                act(gmailAction.move(label.id));
              },
            })),
          },
        ]}
      />
      <View style={styles.bar}>
        {actions
          .filter(({ disabled }) => disabled === undefined)
          .map(({ name, label, action }) => (
            <ActionButton
              key={name}
              label={label}
              onPress={() => {
                act(action);
              }}
            />
          ))}
        <ActionButton
          label={
            folders
              ? t(
                  labeling
                    ? 'gmailActions.hideFolders'
                    : 'gmailActions.folders',
                )
              : t(labeling ? 'gmailActions.hideLabels' : 'gmailActions.labels')
          }
          onPress={() => {
            setLabeling(!labeling);
          }}
        />
      </View>
      {labeling ? (
        <View style={styles.panel}>
          {state.labels.length === 0 ? (
            <Text style={[styles.secondary, { color: colors.secondary }]}>
              {t(folders ? 'gmailActions.noFolders' : 'gmailActions.noLabels')}
            </Text>
          ) : null}
          {state.labelsLimited === true ? (
            <Text style={[styles.secondary, { color: colors.secondary }]}>
              {t('gmailActions.foldersLimited', { count: state.labels.length })}
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
                  act(gmailAction.move(label.id));
                }}
              />
            </View>
          ))}
        </View>
      ) : null}
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
  const imap =
    state.kind === 'ready' && 'receiveOnly' in state ? state : undefined;
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
          style={[styles.secondary, { color: colors.foreground }]}>
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
        <Text style={[styles.secondary, { color: colors.secondary }]}>
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
          style={[styles.secondary, { color: colors.foreground }]}>
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
          style={[styles.secondary, { color: colors.secondary }]}>
          {t('gmailActions.saving')}
        </Text>
      ) : null}
      {state.blockedAction === undefined ? null : (
        <>
          <Text
            accessibilityRole="alert"
            style={[styles.secondary, { color: colors.secondary }]}>
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
        <Text style={[styles.secondary, { color: colors.secondary }]}>
          {t('gmailActions.pending', { count: state.pending, provider })}
        </Text>
      ) : null}
    </View>
  );
}
