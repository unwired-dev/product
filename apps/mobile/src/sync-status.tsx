import { spacing, typography } from '@private-email/mail-core/theme';
import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { InboxMailbox } from './private-storage.ts';

import {
  Glass,
  SFSymbol,
  useMenuMotion,
  useOutcomeAnnouncement,
} from './design.tsx';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

// The Sync Status Capsule floating above the Inbox bar, from the "Sync Status Capsule" Figma
// component (Progress and Attention).
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
    ...typography.ios.footnote,
    lineHeight: 17,
    flex: 1,
  },
  // A 44pt target around the 17pt label, without growing the capsule.
  action: {
    minHeight: 44,
    marginVertical: -14,
    justifyContent: 'center',
  },
  actionLabel: {
    ...typography.ios.footnote,
    lineHeight: 17,
    fontWeight: '600',
  },
  track: {
    marginTop: 7,
    height: 3,
    borderRadius: 1.5,
    overflow: 'hidden',
  },
  value: {
    height: 3,
    borderRadius: 1.5,
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

// All Mail's Historical Metadata Backfill, while it still has older mail to download.
const backfill = (state: InboxMailbox['state']) =>
  state.kind === 'ready' && 'history' in state && !state.history?.complete
    ? state.history
    : undefined;

type SyncStatus =
  | Readonly<{ kind: 'attention'; count: number }>
  | Readonly<{ kind: 'progress'; count: number; percent?: number }>;

// One status for the shown mailboxes, undefined when idle. A failure replaces progress, and
// progress is measurable while some backfill knows its total.
export const syncStatusOf = (
  shown: readonly InboxMailbox[],
): SyncStatus | undefined => {
  const failed = shown.filter(({ state }) => offline(state)).length;
  if (failed > 0) {
    return { kind: 'attention', count: failed };
  }
  const updating = shown.filter(
    ({ state }) => checking(state) || backfill(state) !== undefined,
  ).length;
  if (updating === 0) {
    return undefined;
  }
  let downloaded = 0;
  let total = 0;
  for (const { state } of shown) {
    const history = backfill(state);
    if (history?.total !== undefined && history.total > 0) {
      downloaded += Math.min(history.downloaded, history.total);
      total += history.total;
    }
  }
  return total === 0
    ? { kind: 'progress', count: updating }
    : {
        kind: 'progress',
        count: updating,
        percent: Math.floor((downloaded / total) * 100),
      };
};

// Automatic work shows only after a second; work the person started shows at once.
const automaticDelay = 1000;

type Shown = Readonly<{
  kind: SyncStatus['kind'];
  label: string;
  percent: number | undefined;
}>;

type Translate = ReturnType<typeof useLocalization>['t'];

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

export function SyncStatusCapsule({
  status,
  started,
  onTryAgain,
}: {
  readonly status: SyncStatus | undefined;
  // While a refresh or Try Again the person started runs.
  readonly started: boolean;
  readonly onTryAgain: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const progressing = status?.kind === 'progress';
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
  const current = status === undefined ? undefined : describe(t, status);
  const open =
    current !== undefined &&
    (current.kind === 'attention' || started || waited);
  // The closing capsule keeps what it last said while it fades.
  const [last, setLast] = useState(current);
  if (
    open &&
    (last?.label !== current.label || last.percent !== current.percent)
  ) {
    setLast(current);
  }
  const [height, setHeight] = useState(0);
  const motion = useMenuMotion(open, 'menu');
  useOutcomeAnnouncement(
    current?.kind === 'attention' ? current.label : undefined,
    true,
  );
  const said = open ? current : last;
  if (!motion.shown || said === undefined) {
    return null;
  }
  return (
    <Animated.View
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
      {said.kind === 'attention' ? (
        <Attention
          label={said.label}
          onTryAgain={onTryAgain}
        />
      ) : (
        <Progress
          label={said.label}
          percent={said.percent}
        />
      )}
    </Animated.View>
  );
}

function Attention({
  label,
  onTryAgain,
}: {
  readonly label: string;
  readonly onTryAgain: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  return (
    <View style={styles.status}>
      <SFSymbol
        name="exclamationmark.triangle.fill"
        color={colors.statusWarning}
      />
      <Text style={[styles.message, { color: colors.textPrimary }]}>
        {label}
      </Text>
      <Pressable
        accessibilityRole="button"
        onPress={onTryAgain}
        style={styles.action}>
        <Text style={[styles.actionLabel, { color: colors.accentInk }]}>
          {t('syncStatus.tryAgain')}
        </Text>
      </Pressable>
    </View>
  );
}

function Progress({
  label,
  percent,
}: {
  readonly label: string;
  readonly percent: number | undefined;
}) {
  const colors = usePalette();
  return (
    <View
      accessible
      accessibilityLabel={label}
      accessibilityRole="progressbar"
      accessibilityValue={
        percent === undefined ? undefined : { min: 0, max: 100, now: percent }
      }>
      <View style={styles.status}>
        <ActivityIndicator
          size="small"
          color={colors.textSecondary}
        />
        <Text style={[styles.message, { color: colors.textPrimary }]}>
          {label}
        </Text>
      </View>
      {percent === undefined ? null : (
        <View style={[styles.track, { backgroundColor: colors.fillTrack }]}>
          <View
            style={[
              styles.value,
              { width: `${percent}%`, backgroundColor: colors.accentFill },
            ]}
          />
        </View>
      )}
    </View>
  );
}
