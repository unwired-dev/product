import type { Translate } from '@private-email/localization';
import type { StyleProp, ViewStyle } from 'react-native';

import { lastUpdated } from '@private-email/localization';
import { spacing } from '@private-email/mail-core/theme';
import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { InboxMailbox } from './private-storage.ts';

import { Action } from './action.tsx';
import {
  AnimatedPanel,
  Glass,
  Popover,
  SFSymbol,
  useMenuMotion,
  useOutcomeAnnouncement,
} from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization, useMessageListDateFormats } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

// The Sync Status Capsule floating above the Inbox search bar, and the popover it opens, from the
// Mac "Sync Status Capsule" and "Popover · Sync Status" Figma frames.
const styles = StyleSheet.create({
  capsule: {
    width: 300,
    maxWidth: '100%',
    paddingHorizontal: spacing.l,
    paddingTop: 10,
    paddingBottom: 12,
  },
  // Without a progress bar the capsule is one line high.
  line: {
    paddingBottom: 10,
  },
  status: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  message: {
    ...textStyles.body,
    lineHeight: 17,
    flex: 1,
  },
  // A 28pt target around the 16pt Try Again label, without growing its 17pt line.
  inline: {
    marginVertical: -6,
  },
  // A connection's warning sits closer to its title than the capsule's.
  title: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  track: {
    height: 3,
    borderRadius: 1.5,
    overflow: 'hidden',
  },
  fill: {
    height: '100%',
    borderRadius: 1.5,
  },
  capsuleTrack: {
    marginTop: 7,
  },
  details: {
    width: 340,
    paddingHorizontal: spacing.l,
    paddingTop: 14,
    paddingBottom: 14,
    gap: spacing.m,
  },
  connection: {
    gap: spacing.xs,
  },
  separator: {
    height: 1,
  },
  subtitle: {
    ...textStyles.subheadline,
  },
});

// A Gmail or IMAP Inbox still checking its server.
export const checking = (state: InboxMailbox['state']) =>
  state.kind === 'loading' ||
  (state.kind === 'ready' &&
    (('sync' in state && state.sync === 'syncing') ||
      ('status' in state && state.status === 'syncing')));

// A mailbox whose server could not be reached shows the mail saved on this device.
export const offline = (state: InboxMailbox['state']) =>
  state.kind === 'ready' &&
  (('sync' in state && state.sync === 'retry') ||
    ('status' in state && state.status === 'retry'));

// Authorization was refused, so the provider shows no new mail until it is given again.
const refused = (state: InboxMailbox['state']) =>
  state.kind === 'ready' &&
  (('sync' in state && state.sync === 'authentication') ||
    ('status' in state && state.status === 'authentication'));

// All Mail's Historical Metadata Backfill, while it still has older mail to download.
const backfill = (state: InboxMailbox['state']) =>
  state.kind === 'ready' && 'history' in state && !state.history?.complete
    ? state.history
    : undefined;

// A mailbox that needs attention: authorization was refused, its server could not be reached,
// or a failed read paused its backfill until the next synchronization.
export const failed = (state: InboxMailbox['state']) =>
  offline(state) || backfill(state)?.paused === true || refused(state);

type SyncStatus =
  | Readonly<{ kind: 'attention'; count: number }>
  | Readonly<{ kind: 'progress'; count: number; percent?: number }>;

// How far some backfills have come together, undefined until one knows its total.
const percentOf = (states: ReadonlyArray<InboxMailbox['state']>) => {
  let downloaded = 0;
  let total = 0;
  for (const state of states) {
    const history = backfill(state);
    if (history?.total !== undefined && history.total > 0) {
      downloaded += Math.min(history.downloaded, history.total);
      total += history.total;
    }
  }
  return total === 0 ? undefined : Math.floor((downloaded / total) * 100);
};

// One status for the shown mailboxes, undefined when idle. A failure replaces progress, and
// progress is measurable while some backfill knows its total.
export const syncStatusOf = (
  shown: readonly InboxMailbox[],
): SyncStatus | undefined => {
  const attention = shown.filter(({ state }) => failed(state)).length;
  if (attention > 0) {
    return { kind: 'attention', count: attention };
  }
  const updating = shown.filter(
    ({ state }) => checking(state) || backfill(state) !== undefined,
  ).length;
  if (updating === 0) {
    return undefined;
  }
  const percent = percentOf(shown.map(({ state }) => state));
  return percent === undefined
    ? { kind: 'progress', count: updating }
    : { kind: 'progress', count: updating, percent };
};

// Automatic work shows only after a second; work the person started shows at once.
const automaticDelay = 1000;

type Shown = Readonly<{
  kind: SyncStatus['kind'];
  label: string;
  percent: number | undefined;
}>;

// What the capsule says about a status, with the combined percentage while progress is measurable.
const describe = (t: Translate, status: SyncStatus): Shown => {
  if (status.kind === 'attention') {
    return {
      kind: 'attention',
      label: t('syncStatus.attention', { count: status.count }),
      percent: undefined,
    };
  }
  const message = t('syncStatus.updating', { count: status.count });
  return {
    kind: 'progress',
    label:
      status.percent === undefined
        ? message
        : t('syncStatus.progress', {
            status: message,
            percent: status.percent,
          }),
    percent: status.percent,
  };
};

// Whether progress has lasted long enough to show automatic work.
const useWaited = (progressing: boolean) => {
  const [waited, setWaited] = useState(false);
  if (!progressing && waited) {
    setWaited(false);
  }
  useEffect(() => {
    if (!progressing) {
      return;
    }
    const timer = setTimeout(() => {
      setWaited(true);
    }, automaticDelay);
    return () => {
      clearTimeout(timer);
    };
  }, [progressing]);
  return waited;
};

// Clicking the capsule opens each connection's state in a popover, where each connection that
// needs attention is tried again on its own.
export function SyncStatusCapsule({
  shown,
  refreshing,
  now,
  onTryAgain,
}: {
  readonly shown: readonly InboxMailbox[];
  // While a refresh the person started runs.
  readonly refreshing: boolean;
  readonly now: number;
  // Synchronizes these mailboxes again.
  readonly onTryAgain: (loaded: readonly InboxMailbox[]) => Promise<void>;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const status = syncStatusOf(shown);
  const waited = useWaited(status?.kind === 'progress');
  const [retrying, setRetrying] = useState(false);
  const [details, setDetails] = useState(false);
  const tryAgain = async (loaded: readonly InboxMailbox[]) => {
    setRetrying(true);
    try {
      await onTryAgain(loaded);
    } catch {
      // The capsule keeps reporting the failure, and the list keeps its saved mail.
    }
    // Not in `finally`: React Compiler cannot compile a finally clause.
    setRetrying(false);
  };
  const current = status === undefined ? undefined : describe(t, status);
  const open =
    current !== undefined &&
    (current.kind === 'attention' || refreshing || retrying || waited);
  // The closing capsule keeps what it last said while it fades.
  const [last, setLast] = useState(current);
  if (
    open &&
    (last?.label !== current.label || last.percent !== current.percent)
  ) {
    setLast(current);
  }
  // The popover closes with the capsule.
  if (!open && details) {
    setDetails(false);
  }
  const [height, setHeight] = useState(0);
  const motion = useMenuMotion(open, 'grow');
  useOutcomeAnnouncement(
    current?.kind === 'attention' ? current.label : undefined,
    true,
  );
  const said = open ? current : last;
  if (!motion.shown || said === undefined) {
    return null;
  }
  return (
    <AnimatedPanel
      accessibilityElementsHidden={!open}
      pointerEvents={open ? 'auto' : 'none'}
      onLayout={({ nativeEvent }) => {
        setHeight(nativeEvent.layout.height);
      }}
      style={[
        styles.capsule,
        said.percent === undefined && styles.line,
        { borderRadius: height / 2, boxShadow: colors.smallGlassShadow },
        motion.style,
      ]}>
      <Glass cornerRadius={height / 2} />
      <CapsuleStatus
        said={said}
        onShowDetails={() => {
          setDetails(true);
        }}
        onTryAgain={() => {
          void tryAgain(shown.filter(({ state }) => failed(state)));
        }}
      />
      <Popover
        shown={details}
        onClose={() => {
          setDetails(false);
        }}>
        <SyncStatusDetails
          shown={shown}
          now={now}
          onTryAgain={(mailbox) => {
            void tryAgain([mailbox]);
          }}
        />
      </Popover>
    </AnimatedPanel>
  );
}

// The capsule's one line: a failure with its Try Again, or progress with a bar while measurable.
function CapsuleStatus({
  said,
  onShowDetails,
  onTryAgain,
}: {
  readonly said: Shown;
  readonly onShowDetails: () => void;
  readonly onTryAgain: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  return said.kind === 'attention' ? (
    <View style={styles.status}>
      <Pressable
        accessibilityHint={t('syncStatus.showDetails')}
        accessibilityLabel={said.label}
        accessibilityRole="button"
        onPress={onShowDetails}
        style={[styles.status, { flex: 1 }]}>
        <SFSymbol
          name="exclamationmark.triangle.fill"
          color={colors.statusWarning}
        />
        <Text style={[styles.message, { color: colors.textPrimary }]}>
          {said.label}
        </Text>
      </Pressable>
      <View style={styles.inline}>
        <Action
          label={t('syncStatus.tryAgain')}
          onPress={onTryAgain}
          variant="banner"
        />
      </View>
    </View>
  ) : (
    <Pressable
      accessibilityHint={t('syncStatus.showDetails')}
      accessibilityLabel={said.label}
      accessibilityRole="button"
      accessibilityValue={
        said.percent === undefined
          ? undefined
          : { min: 0, max: 100, now: said.percent }
      }
      onPress={onShowDetails}>
      <View style={styles.status}>
        <ActivityIndicator
          size={16}
          color={colors.textSecondary}
        />
        <Text style={[styles.message, { color: colors.textPrimary }]}>
          {said.label}
        </Text>
      </View>
      {said.percent === undefined ? null : (
        <ProgressBar
          percent={said.percent}
          style={styles.capsuleTrack}
        />
      )}
    </Pressable>
  );
}

// A 3pt bar in the accent color. React Native macOS 0.81.9 has no determinate progress view, and
// NSProgressIndicator draws in the system accent rather than the documented `accentFill`.
function ProgressBar({
  percent,
  style,
}: {
  readonly percent: number;
  readonly style?: StyleProp<ViewStyle>;
}) {
  const colors = usePalette();
  return (
    <View style={[styles.track, { backgroundColor: colors.fillTrack }, style]}>
      <View
        style={[
          styles.fill,
          { width: `${percent}%`, backgroundColor: colors.accentFill },
        ]}
      />
    </View>
  );
}

// Each shown connection's state, its backfill's progress and, when it needs attention, its own
// Try Again; below them, when the shown mailboxes were last brought up to date.
function SyncStatusDetails({
  shown,
  now,
  onTryAgain,
}: {
  readonly shown: readonly InboxMailbox[];
  readonly now: number;
  readonly onTryAgain: (mailbox: InboxMailbox) => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const { time } = useMessageListDateFormats();
  const synchronizedAt = shown.flatMap(({ state }) =>
    state.kind === 'ready' &&
    'synchronizedAt' in state &&
    state.synchronizedAt !== undefined
      ? [state.synchronizedAt]
      : [],
  );
  const oldest =
    synchronizedAt.length === 0
      ? undefined
      : Math.min(...synchronizedAt.map((at) => Date.parse(at)));
  return (
    <View
      testID="sync-status-details"
      style={styles.details}>
      <Label
        accessibilityRole="header"
        style={[
          textStyles.bodyEmphasized,
          { lineHeight: 17, color: colors.textPrimary },
        ]}>
        {t('syncStatus.title')}
      </Label>
      {shown.map((mailbox, index) => (
        <View
          key={mailbox.id}
          style={styles.connection}>
          {index === 0 ? null : (
            <View
              style={[
                styles.separator,
                { backgroundColor: colors.separator, marginBottom: spacing.s },
              ]}
            />
          )}
          <Connection
            mailbox={mailbox}
            now={now}
            onTryAgain={() => {
              onTryAgain(mailbox);
            }}
          />
        </View>
      ))}
      <Label style={[styles.subtitle, { color: colors.textSecondary }]}>
        {oldest === undefined
          ? t('syncStatus.refresh')
          : t('syncStatus.updatedAt', { time: time.format(oldest) })}
      </Label>
    </View>
  );
}

// What one connection is doing, as its row in the popover says it.
const connectionStatus = (
  t: Translate,
  { provider, state }: InboxMailbox,
  now: number,
) => {
  const name = t(`mailProviders.${provider ?? 'gmail'}`);
  const imap = provider === 'imap';
  if (state.kind === 'locked' || state.kind === 'failed') {
    return t(state.kind === 'locked' ? 'storage.locked' : 'storage.failed');
  }
  if (refused(state)) {
    return imap
      ? t('imapSync.authentication')
      : t('gmailSync.authentication', { provider: name });
  }
  if (failed(state)) {
    return imap
      ? t('imapSync.retry')
      : t('gmailSync.retry', { provider: name });
  }
  const history = backfill(state);
  if (history !== undefined) {
    return history.total === undefined
      ? t('syncStatus.historyDownloaded', { downloaded: history.downloaded })
      : t('syncStatus.history', {
          downloaded: history.downloaded,
          total: history.total,
        });
  }
  if (checking(state)) {
    return imap
      ? t('imapSync.syncing')
      : t('gmailSync.syncing', { provider: name });
  }
  const updated =
    state.kind === 'ready' &&
    'synchronizedAt' in state &&
    state.synchronizedAt !== undefined
      ? lastUpdated(t, [state.synchronizedAt], now)
      : undefined;
  return updated === undefined
    ? t('syncStatus.upToDate')
    : t('syncStatus.upToDateUpdated', { updated });
};

function Connection({
  mailbox,
  now,
  onTryAgain,
}: {
  readonly mailbox: InboxMailbox;
  readonly now: number;
  readonly onTryAgain: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const attention = failed(mailbox.state);
  const percent = percentOf([mailbox.state]);
  const title = `${t(`mailProviders.${mailbox.provider ?? 'gmail'}`)} · ${
    mailbox.address ?? mailbox.id
  }`;
  return (
    <>
      <View style={styles.title}>
        {attention ? (
          <SFSymbol
            name="exclamationmark.triangle.fill"
            color={colors.statusWarning}
          />
        ) : null}
        <View style={{ flex: 1 }}>
          <Label
            style={[
              textStyles.body,
              { lineHeight: 17, color: colors.textPrimary },
            ]}>
            {title}
          </Label>
        </View>
        {attention ? (
          <View style={styles.inline}>
            <Action
              accessibilityLabel={t('syncStatus.tryAgainFor', {
                account: title,
              })}
              label={t('syncStatus.tryAgain')}
              onPress={onTryAgain}
              variant="banner"
            />
          </View>
        ) : null}
      </View>
      <Label style={[styles.subtitle, { color: colors.textSecondary }]}>
        {connectionStatus(t, mailbox, now)}
      </Label>
      {percent === undefined ? null : (
        <View
          accessible
          accessibilityLabel={title}
          accessibilityRole="progressbar"
          accessibilityValue={{ min: 0, max: 100, now: percent }}>
          <ProgressBar percent={percent} />
        </View>
      )}
    </>
  );
}
