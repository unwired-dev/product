import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type { OrganizeNotice } from '@private-email/mail-core/gmail-inbox';

import {
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
  const [labeling, setLabeling] = useState(false);
  if (state.kind !== 'ready' || !('sync' in state) || !('organize' in store)) {
    return null;
  }
  const message = state.messages.find((item) => item.id === id);
  if (message === undefined) {
    return null;
  }
  if (!state.organize) {
    return (
      <Text style={[styles.secondary, { color: colors.secondary }]}>
        {gmailActionCopy.savedOnly}
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
        {quickActions(message).map(({ name, label, action }) => (
          <ActionButton
            key={name}
            label={label}
            onPress={() => {
              act(action);
            }}
          />
        ))}
        <ActionButton
          label={labeling ? 'Hide labels' : 'Labels'}
          onPress={() => {
            setLabeling(!labeling);
          }}
        />
      </View>
      {labeling ? (
        <View style={styles.panel}>
          {state.labels.length === 0 ? (
            <Text style={[styles.secondary, { color: colors.secondary }]}>
              This Gmail mailbox has no labels of its own yet.
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
                label={`Move to ${label.name}`}
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
  const notice =
    state.kind === 'ready' && 'notice' in state ? state.notice : undefined;
  // VoiceOver announces the outcome once, however many windows show it; the action that caused it
  // may have closed the reader.
  useEffect(() => {
    if (notice !== undefined && !announced.has(notice)) {
      announced.add(notice);
      AccessibilityInfo.announceForAccessibility(
        gmailActionCopy[notice.kind](notice.action, notice.message.subject),
      );
    }
  }, [notice]);
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
        <Text
          accessibilityLiveRegion="polite"
          accessibilityRole={notice.kind === 'rejected' ? 'alert' : 'text'}
          style={[styles.secondary, { color: colors.foreground }]}>
          {gmailActionCopy[notice.kind](notice.action, notice.message.subject)}
        </Text>
      )}
      {notice?.kind === 'done' && undo !== undefined ? (
        <View style={styles.bar}>
          <ActionButton
            label="Undo"
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
          Saving the change on this device…
        </Text>
      ) : null}
      {state.blockedAction === undefined ? null : (
        <>
          <Text
            accessibilityRole="alert"
            style={[styles.secondary, { color: colors.secondary }]}>
            {gmailActionCopy.blocked(
              state.blockedAction.action,
              state.blockedAction.message.subject,
            )}
          </Text>
          <View style={styles.bar}>
            <ActionButton
              label="Retry change"
              onPress={() => {
                void store.resolvePending('retry', state.blockedAction?.id);
              }}
            />
            <ActionButton
              label="Discard change"
              onPress={() => {
                void store.resolvePending('discard', state.blockedAction?.id);
              }}
            />
          </View>
        </>
      )}
      {waiting ? (
        <Text style={[styles.secondary, { color: colors.secondary }]}>
          {gmailActionCopy.pending(state.pending)}
        </Text>
      ) : null}
    </View>
  );
}
