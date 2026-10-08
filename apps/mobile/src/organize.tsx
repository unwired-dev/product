import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type { OrganizeNotice } from '@private-email/mail-core/gmail-inbox';

import {
  canOrganize,
  gmailAction,
  gmailActionCopy,
  restoreAfter,
  quickActions,
} from '@private-email/mail-core/gmail-actions';
import { spacing } from '@private-email/mail-core/theme';
import { useEffect, useState } from 'react';
import {
  AccessibilityInfo,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { useLocalization } from './localization.ts';
import { useInbox, useInboxActions } from './mailbox.tsx';
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

// The reader's actions. A message that leaves the Inbox closes the reader.
export function MessageActions({
  id,
  onClose,
}: {
  readonly id: string;
  readonly onClose?: (() => void) | undefined;
}) {
  const state = useInbox();
  const store = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const [labeling, setLabeling] = useState(false);
  if (state.kind !== 'ready' || !('sync' in state) || !('organize' in store)) {
    return null;
  }
  const message = state.messages.find((item) => item.id === id);
  if (message === undefined || !canOrganize(message)) {
    return null;
  }
  if (!state.organize) {
    return (
      <Text style={[styles.secondary, { color: colors.secondary }]}>
        {t('gmailActions.savedOnly')}
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
  return (
    <>
      <View style={styles.bar}>
        {quickActions(t, message).map(({ name, label, action }) => (
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
            labeling ? t('gmailActions.hideLabels') : t('gmailActions.labels')
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
              {t('gmailActions.noLabels')}
            </Text>
          ) : null}
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

const announced = new WeakSet<OrganizeNotice>();

// The latest organizing outcome, and changes that still wait for Gmail.
export function OrganizeStatus() {
  const state = useInbox();
  const store = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const notice =
    state.kind === 'ready' && 'notice' in state ? state.notice : undefined;
  // VoiceOver announces the outcome once, however many windows show it; the action that caused it
  // may have closed the reader.
  useEffect(() => {
    if (notice !== undefined && !announced.has(notice)) {
      announced.add(notice);
      AccessibilityInfo.announceForAccessibility(gmailActionCopy(t, notice));
    }
  }, [notice, t]);
  if (state.kind !== 'ready' || !('sync' in state) || !('organize' in store)) {
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
          {gmailActionCopy(t, notice)}
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
            {gmailActionCopy(t, { ...state.blockedAction, kind: 'blocked' })}
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
          {t('gmailActions.pending', { count: state.pending })}
        </Text>
      ) : null}
    </View>
  );
}
