import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type {
  ImapAction,
  ImapInbox,
} from '@private-email/mail-core/imap-inbox';
import type { ReactNode } from 'react';

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
import { radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useState, useSyncExternalStore } from 'react';
import {
  AccessibilityInfo,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from 'react-native';

import { GlassGroup, GlassPanel, SFSymbol, ToolbarButton } from './design.tsx';
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
  // Panels open above a bottom toolbar and below a top one; the reader positions the whole.
  panels: { maxHeight: 280, flexGrow: 0 },
  floatingPanels: {
    position: 'absolute',
    top: 52 + spacing.m,
    right: spacing.l,
    gap: spacing.s,
  },
  button: {
    minHeight: 44,
    minWidth: 44,
    maxWidth: '100%',
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.m,
    borderWidth: 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.subheadline, flexShrink: 1 },
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

// The reader's actions for the message's provider: one glass toolbar of Archive, Move, the
// response actions passed as children, and More, whose panel lists the remaining actions.
export function MessageActions({
  id,
  onClose,
  children,
}: {
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
  readonly children?: ReactNode;
}) {
  const store = useInboxActions();
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
      onClose={onClose}>
      {children}
    </GmailMessageActions>
  );
}

// The toolbar and the panel one of its buttons opened.
function Toolbar({
  archive,
  folders,
  more,
  children,
}: {
  readonly archive: (() => void) | undefined;
  readonly folders:
    | Readonly<{
        label: string;
        open: boolean;
        toggle: () => void;
        panel: ReactNode;
      }>
    | undefined;
  readonly more: Readonly<{
    open: boolean;
    toggle: () => void;
    panel: ReactNode;
  }>;
  readonly children: ReactNode;
}) {
  const { t } = useLocalization();
  const compact = useWindowDimensions().width < 700;
  return (
    <>
      <View style={styles.toolbar}>
        <GlassGroup>
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
              onPress={() => {
                folders.toggle();
              }}
            />
          )}
          {children}
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
      {folders?.open === true || more.open ? (
        <View style={compact ? undefined : styles.floatingPanels}>
          {folders?.open === true ? (
            <GlassPanel>{folders.panel}</GlassPanel>
          ) : null}
          {more.open ? <GlassPanel>{more.panel}</GlassPanel> : null}
        </View>
      ) : null}
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
  // At most one panel is open: the folders to move to, or the remaining actions.
  const [panel, setPanel] = useState<'folders' | 'more'>();
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
  const toggle = (which: 'folders' | 'more') => {
    setPanel(panel === which ? undefined : which);
  };
  return (
    <Toolbar
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
              panel: (
                <ScrollView style={styles.panels}>
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
                </ScrollView>
              ),
            }
      }
      more={{
        open: panel === 'more',
        toggle: () => {
          toggle('more');
        },
        panel: (
          <ScrollView style={styles.panels}>
            <View style={styles.panel}>
              {actions
                .filter(({ name }) => name !== 'archive')
                .map(({ name, label, action }) => (
                  <ActionButton
                    key={name}
                    label={label}
                    onPress={() => {
                      act(action);
                    }}
                  />
                ))}
            </View>
          </ScrollView>
        ),
      }}>
      {children}
    </Toolbar>
  );
}

// The reader's Gmail and Microsoft actions. A message that leaves the Inbox closes the reader.
function GmailMessageActions({
  id,
  onClose,
  children,
}: {
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
  readonly children: ReactNode;
}) {
  const state = useInbox();
  const store = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  // At most one panel is open: the labels or folders, or the remaining actions.
  const [panel, setPanel] = useState<'folders' | 'more'>();
  const provider = useMailbox()?.provider ?? 'gmail';
  const providerName = useProviderName();
  if (
    state.kind !== 'ready' ||
    !('sync' in state) ||
    !('resolvePending' in store)
  ) {
    return null;
  }
  const message = state.messages.find((item) => item.id === id);
  // Responses also work for online results and saved mail without organizing permission.
  if (message === undefined || !canOrganize(message)) {
    return <GlassGroup>{children}</GlassGroup>;
  }
  if (!state.organize) {
    return (
      <>
        <GlassGroup>{children}</GlassGroup>
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('gmailActions.savedOnly', { provider: providerName })}
        </Text>
      </>
    );
  }
  const act = (action: GmailAction) => {
    void store.organize(message, action);
    if (restoreAfter(action) !== undefined) {
      onClose?.();
    }
  };
  const applied = new Set(message.labels);
  // A Microsoft message is in one folder: it moves, but has no labels to add or remove.
  const folders = provider !== 'gmail';
  const actions = quickActions(t, message, {
    provider,
    unavailableActions: state.unavailableActions,
  });
  const archive = actions.find(({ name }) => name === 'archive');
  const toggle = (which: 'folders' | 'more') => {
    setPanel(panel === which ? undefined : which);
  };
  return (
    <Toolbar
      archive={
        archive === undefined
          ? undefined
          : () => {
              act(archive.action);
            }
      }
      folders={{
        label: folders
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
        toggle: () => {
          toggle('folders');
        },
        panel: (
          <ScrollView style={styles.panels}>
            <View style={styles.panel}>
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
                      act(gmailAction.move(label.id));
                    }}
                  />
                </View>
              ))}
            </View>
          </ScrollView>
        ),
      }}
      more={{
        open: panel === 'more',
        toggle: () => {
          toggle('more');
        },
        panel: (
          <ScrollView style={styles.panels}>
            <View style={styles.panel}>
              {actions
                .filter(({ name }) => name !== 'archive')
                .map(({ name, label, action }) => (
                  <ActionButton
                    key={name}
                    label={label}
                    onPress={() => {
                      act(action);
                    }}
                  />
                ))}
            </View>
          </ScrollView>
        ),
      }}>
      {children}
    </Toolbar>
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
