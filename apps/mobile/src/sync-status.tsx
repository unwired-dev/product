import type { Translate } from '@private-email/localization';
import type { ReactElement } from 'react';

import {
  BottomSheet,
  Group,
  Host,
  Popover,
  ProgressView,
  RNHostView,
} from '@expo/ui/swift-ui';
import {
  presentationDetents,
  presentationDragIndicator,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { lastUpdated } from '@private-email/localization';
import { spacing, typography } from '@private-email/mail-core/theme';
import { Fragment, use, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Pressable,
  ScrollView,
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
import { WindowBarContext } from './inbox-bar.tsx';
import { useLocalization, useMessageListDateFormats } from './localization.ts';
import { usePalette } from './theme.ts';

// The Sync Status Capsule floating above the Inbox bar, from the "Sync Status Capsule" Figma
// component (Progress and Attention), and the details it opens from the "Sheet · Sync Status"
// and "Popover · Sync Status" frames.
const styles = StyleSheet.create({
  capsule: {
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
  },
  // The header starts below the system grabber.
  sheet: {
    paddingTop: 28,
    paddingHorizontal: spacing.xl,
    paddingBottom: 40,
    gap: 14,
  },
  popover: {
    width: 360,
    paddingHorizontal: spacing.l,
    paddingVertical: 14,
    gap: spacing.m,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  sheetTitle: {
    ...typography.ios.headline,
  },
  popoverTitle: {
    ...typography.ios.subheadline,
    fontWeight: '600',
  },
  // A 44pt target around Done, without growing the header.
  done: {
    minHeight: 44,
    marginVertical: -11,
    justifyContent: 'center',
  },
  connection: {
    gap: spacing.xs,
  },
  // A connection's warning sits closer to its title than the capsule's.
  connectionTitle: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  title: {
    ...typography.ios.subheadline,
    flex: 1,
  },
  // A 44pt target around the 20pt label, without growing the row.
  rowAction: {
    minHeight: 44,
    marginVertical: -12,
    justifyContent: 'center',
  },
  rowActionLabel: {
    ...typography.ios.subheadline,
    fontWeight: '600',
  },
  detail: {
    ...typography.ios.footnote,
    lineHeight: 17,
  },
  separator: {
    height: 1,
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

// The list column of a regular-width window gives the capsule more room.
const useCapsuleWidth = () => (use(WindowBarContext) === undefined ? 300 : 320);

// A regular-width window shows the details in a popover rather than a sheet.
const usePopover = () => use(WindowBarContext) !== undefined;

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

// Tapping the capsule opens each connection's state, where each connection that needs attention
// is tried again or authorized on its own: a popover on the capsule when the bar spans a
// regular-width window, otherwise a medium-detent sheet.
export function SyncStatusCapsule({
  shown,
  refreshing,
  now,
  onTryAgain,
  onAuthorize,
}: {
  readonly shown: readonly InboxMailbox[];
  // While a refresh the person started runs.
  readonly refreshing: boolean;
  readonly now: number;
  // Synchronizes these mailboxes again.
  readonly onTryAgain: (loaded: readonly InboxMailbox[]) => Promise<void>;
  // Asks again for the access a mailbox's provider refused, when the Inbox can.
  readonly onAuthorize: ((mailbox: InboxMailbox) => void) | undefined;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const width = useCapsuleWidth();
  const status = syncStatusOf(shown);
  const waited = useWaited(status?.kind === 'progress');
  const [retrying, setRetrying] = useState(false);
  const [details, setDetails] = useState(false);
  const tryAgain = async (loaded: readonly InboxMailbox[]) => {
    setRetrying(true);
    await onTryAgain(loaded);
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
  // The details close with the capsule.
  if (!open && details) {
    setDetails(false);
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
  const capsule = (
    <Animated.View
      accessibilityElementsHidden={!open}
      pointerEvents={open ? 'auto' : 'none'}
      onLayout={({ nativeEvent }) => {
        setHeight(nativeEvent.layout.height);
      }}
      style={[
        styles.capsule,
        said.percent === undefined && styles.line,
        {
          width,
          borderRadius: height / 2,
          boxShadow: colors.smallGlassShadow,
        },
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
    </Animated.View>
  );
  const content = (
    <SyncStatusDetails
      shown={shown}
      now={now}
      onDone={() => {
        setDetails(false);
      }}
      onTryAgain={(mailbox) => {
        void tryAgain([mailbox]);
      }}
      onAuthorize={onAuthorize}
    />
  );
  return (
    <Presenter
      isPresented={details}
      onIsPresentedChange={setDetails}
      trigger={capsule}>
      {content}
    </Presenter>
  );
}

// The details on the capsule: a popover anchored to it, or a medium-detent sheet.
function Presenter({
  isPresented,
  onIsPresentedChange,
  trigger,
  children,
}: {
  readonly isPresented: boolean;
  readonly onIsPresentedChange: (presented: boolean) => void;
  readonly trigger: ReactElement;
  readonly children: ReactElement;
}) {
  return usePopover() ? (
    <Host matchContents>
      <Popover
        isPresented={isPresented}
        onIsPresentedChange={onIsPresentedChange}>
        <Popover.Trigger>
          <RNHostView matchContents>{trigger}</RNHostView>
        </Popover.Trigger>
        <Popover.Content>
          <RNHostView matchContents>{children}</RNHostView>
        </Popover.Content>
      </Popover>
    </Host>
  ) : (
    <>
      {trigger}
      <Host matchContents>
        <BottomSheet
          isPresented={isPresented}
          onIsPresentedChange={onIsPresentedChange}>
          <Group
            modifiers={[
              presentationDetents(['medium']),
              presentationDragIndicator('visible'),
            ]}>
            <RNHostView>{children}</RNHostView>
          </Group>
        </BottomSheet>
      </Host>
    </>
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
      <Pressable
        accessibilityRole="button"
        onPress={onTryAgain}
        style={styles.action}>
        <Text style={[styles.actionLabel, { color: colors.accentInk }]}>
          {t('syncStatus.tryAgain')}
        </Text>
      </Pressable>
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
          size="small"
          color={colors.textSecondary}
        />
        <Text style={[styles.message, { color: colors.textPrimary }]}>
          {said.label}
        </Text>
      </View>
      {said.percent === undefined ? null : (
        <ProgressBar
          percent={said.percent}
          style={styles.track}
        />
      )}
    </Pressable>
  );
}

function ProgressBar({
  percent,
  style,
}: {
  readonly percent: number;
  readonly style?: Parameters<typeof Host>[0]['style'];
}) {
  const colors = usePalette();
  return (
    <Host
      matchContents={{ vertical: true }}
      style={style}>
      <ProgressView
        value={percent / 100}
        modifiers={[tint(colors.accentFill)]}
      />
    </Host>
  );
}

// Each shown connection's state, its backfill's progress and, when it needs attention, its own
// Try Again or authorization; below them, when the shown mailboxes were last brought up to date.
function SyncStatusDetails({
  shown,
  now,
  onDone,
  onTryAgain,
  onAuthorize,
}: {
  readonly shown: readonly InboxMailbox[];
  readonly now: number;
  readonly onDone: () => void;
  readonly onTryAgain: (mailbox: InboxMailbox) => void;
  readonly onAuthorize: ((mailbox: InboxMailbox) => void) | undefined;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const { time } = useMessageListDateFormats();
  const popover = usePopover();
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
  const rows = (
    <>
      <View style={styles.header}>
        <Text
          accessibilityRole="header"
          style={[
            popover ? styles.popoverTitle : styles.sheetTitle,
            { flex: 1, color: colors.textPrimary },
          ]}>
          {t('syncStatus.title')}
        </Text>
        {popover ? null : (
          <Pressable
            accessibilityRole="button"
            onPress={onDone}
            style={styles.done}>
            <Text style={[styles.sheetTitle, { color: colors.accentInk }]}>
              {t('common.done')}
            </Text>
          </Pressable>
        )}
      </View>
      {shown.map((mailbox, index) => (
        <Fragment key={mailbox.id}>
          {index === 0 ? null : (
            <View
              style={[styles.separator, { backgroundColor: colors.separator }]}
            />
          )}
          <Connection
            mailbox={mailbox}
            now={now}
            popover={popover}
            onTryAgain={() => {
              onTryAgain(mailbox);
            }}
            onAuthorize={
              onAuthorize === undefined
                ? undefined
                : () => {
                    // Authorizing presents its own screen.
                    onDone();
                    onAuthorize(mailbox);
                  }
            }
          />
        </Fragment>
      ))}
      <Text style={[styles.detail, { color: colors.textSecondary }]}>
        {oldest === undefined
          ? t('syncStatus.pullToRefresh')
          : t('syncStatus.updatedAtPull', { time: time.format(oldest) })}
      </Text>
    </>
  );
  // A medium-detent sheet scrolls connections that do not fit.
  return popover ? (
    <View
      testID="sync-status-details"
      style={styles.popover}>
      {rows}
    </View>
  ) : (
    <ScrollView
      testID="sync-status-details"
      contentContainerStyle={styles.sheet}>
      {rows}
    </ScrollView>
  );
}

// What one connection is doing, as its row in the details says it.
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

const titleOf = (t: Translate, { provider, address, id }: InboxMailbox) =>
  `${t(`mailProviders.${provider ?? 'gmail'}`)} · ${address ?? id}`;

// The label and accessible name of what a connection that needs attention offers, when the Inbox
// can do it.
const actionOf = (
  t: Translate,
  mailbox: InboxMailbox,
  canAuthorize: boolean,
): Readonly<{ label: string; name?: string }> | undefined => {
  if (!refused(mailbox.state)) {
    return failed(mailbox.state)
      ? {
          label: t('syncStatus.tryAgain'),
          name: t('syncStatus.tryAgainFor', { account: titleOf(t, mailbox) }),
        }
      : undefined;
  }
  if (!canAuthorize) {
    return undefined;
  }
  return mailbox.provider === 'imap'
    ? {
        label: t('settings.enterPassword'),
        name: t('mailboxes.enterPassword', {
          address: mailbox.address ?? mailbox.id,
        }),
      }
    : {
        label: t('common.allowAccess', {
          provider: t(`mailProviders.${mailbox.provider ?? 'gmail'}`),
        }),
      };
};

// A connection whose provider refused access offers the Inbox's authorization in place of Try
// Again: Gmail asks for access again, and IMAP enters the password in Settings.
function Connection({
  mailbox,
  now,
  popover,
  onTryAgain,
  onAuthorize,
}: {
  readonly mailbox: InboxMailbox;
  readonly now: number;
  readonly popover: boolean;
  readonly onTryAgain: () => void;
  readonly onAuthorize: (() => void) | undefined;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const attention = failed(mailbox.state);
  const percent = percentOf([mailbox.state]);
  const title = titleOf(t, mailbox);
  const authorize = refused(mailbox.state);
  const action = actionOf(t, mailbox, onAuthorize !== undefined);
  return (
    <View style={styles.connection}>
      <View style={styles.connectionTitle}>
        {attention ? (
          <SFSymbol
            name="exclamationmark.triangle.fill"
            color={colors.statusWarning}
          />
        ) : null}
        {/* The sheet's titles keep one line; the popover's wrap. */}
        <Text
          numberOfLines={popover ? undefined : 1}
          style={[styles.title, { color: colors.textPrimary }]}>
          {title}
        </Text>
        {action === undefined ? null : (
          <Pressable
            accessibilityLabel={action.name}
            accessibilityRole="button"
            onPress={authorize ? onAuthorize : onTryAgain}
            style={styles.rowAction}>
            <Text style={[styles.rowActionLabel, { color: colors.accentInk }]}>
              {action.label}
            </Text>
          </Pressable>
        )}
      </View>
      <Text style={[styles.detail, { color: colors.textSecondary }]}>
        {connectionStatus(t, mailbox, now)}
      </Text>
      {percent === undefined ? null : (
        <View
          accessible
          accessibilityLabel={title}
          accessibilityRole="progressbar"
          accessibilityValue={{ min: 0, max: 100, now: percent }}>
          <ProgressBar percent={percent} />
        </View>
      )}
    </View>
  );
}
