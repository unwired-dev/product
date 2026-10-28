import type { ErrorReporting } from '@private-email/mail-core/error-reporting';

import { spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  useContext,
  useEffect,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Switch,
  Text,
} from 'react-native';

import type { SettingsDestination } from './settings.tsx';

import { SFSymbol, useConfirmation } from './design.tsx';
import { useLocalization } from './localization.ts';
import { errorReporting } from './registration.ts';
import { SettingsGroup, SettingsRow, SettingsRowButton } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

export const ErrorReportingContext =
  createContext<ErrorReporting>(errorReporting);

const styles = StyleSheet.create({
  action: {
    minHeight: 40,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    paddingVertical: 10,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  label: { flex: 1 },
});

// A pending action stays disabled and shows the system activity indicator until it settles.
function ReportingAction({
  label,
  onPress,
  disabled = false,
  pending = false,
  destructive = false,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly pending?: boolean;
  readonly destructive?: boolean;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled: disabled || pending, busy: pending }}
      disabled={disabled || pending}
      onPress={onPress}
      focusable
      style={({ pressed }) => [
        styles.action,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : 'transparent',
        },
      ]}>
      <Text
        style={[
          textStyles.body,
          styles.label,
          {
            color: pending ? colors.accentInk : colors.textPrimary,
            opacity: disabled || pending ? 0.4 : 1,
          },
          destructive && { color: colors.statusDestructive },
        ]}>
        {label}
      </Text>
      {pending ? (
        <ActivityIndicator
          size="small"
          color={colors.textSecondary}
        />
      ) : null}
    </Pressable>
  );
}

export function ErrorReportingEntry({
  onPress,
}: {
  readonly onPress: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const store = useContext(ErrorReportingContext);
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const status =
    snapshot.kind === 'loading' || snapshot.kind === 'unavailable'
      ? undefined
      : t(
          `errorReporting.${snapshot.kind !== 'deleting' && snapshot.enabled ? 'statusOn' : 'statusOff'}`,
        );
  return (
    <SettingsGroup title={t('errorReporting.title')}>
      <SettingsRowButton
        accessibilityLabel={t('errorReporting.title')}
        accessibilityRole="button"
        accessibilityValue={status === undefined ? undefined : { text: status }}
        onPress={onPress}>
        <SettingsRow title={t('errorReporting.title')}>
          {status === undefined ? null : (
            <Text style={[textStyles.body, { color: colors.textSecondary }]}>
              {status}
            </Text>
          )}
          <SFSymbol
            name="chevron.right"
            size={14}
            color={colors.textSecondary}
          />
        </SettingsRow>
      </SettingsRowButton>
    </SettingsGroup>
  );
}

export function ErrorReportingDestination({
  destination,
  onDestination,
}: {
  readonly destination: SettingsDestination | undefined;
  readonly onDestination: (destination: SettingsDestination) => void;
}) {
  if (destination === 'privacy') {
    return (
      <ErrorReportingEntry
        onPress={() => {
          onDestination('errorReporting');
        }}
      />
    );
  }
  if (destination === 'errorReporting') {
    return <ErrorReportingSettings />;
  }
  return null;
}

export function ErrorReportingSettings({
  store: supplied,
  signedOut = false,
}: {
  readonly store?: ErrorReporting;
  readonly signedOut?: boolean;
}) {
  const shared = useContext(ErrorReportingContext);
  const store = supplied ?? shared;
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [checking, setChecking] = useState(false);
  const { t } = useLocalization();
  const colors = usePalette();
  useEffect(() => {
    store.breadcrumb({ operation: 'settings', stage: 'open' });
    void store.refresh();
  }, [store]);
  const enabled =
    (snapshot.kind === 'ready' || snapshot.kind === 'saving') &&
    snapshot.enabled;
  const available = snapshot.kind === 'ready';
  const missing =
    (snapshot.kind === 'ready' || snapshot.kind === 'saving') &&
    snapshot.deletion === 'missing';
  const complete =
    (snapshot.kind === 'ready' || snapshot.kind === 'saving') &&
    snapshot.deletion === 'complete';
  const { anchor, confirm } = useConfirmation();
  const confirmation = async () => {
    if (
      await confirm({
        title: t('errorReporting.confirmTitle'),
        detail: t('errorReporting.confirmMessage'),
        cancel: t('common.cancel'),
        action: t('errorReporting.confirmDelete'),
      })
    ) {
      await store.deleteReports();
    }
  };
  let consentDescription = signedOut
    ? t('errorReporting.signedOut')
    : t('errorReporting.off');
  if (enabled) {
    consentDescription = t('errorReporting.on');
  }
  let uploaded = null;
  if (snapshot.kind === 'deleting') {
    uploaded = (
      <>
        <SettingsGroup
          title={t('errorReporting.uploaded')}
          footer={t(`errorReporting.${snapshot.phase}Description`)}>
          <SettingsRow title={t(`errorReporting.${snapshot.phase}Title`)} />
        </SettingsGroup>
        <SettingsGroup>
          <ReportingAction
            label={t(
              checking
                ? 'errorReporting.checking'
                : `errorReporting.${snapshot.phase}Action`,
            )}
            pending={checking}
            onPress={() => {
              void (async () => {
                setChecking(true);
                await store.retryDeletion();
                setChecking(false);
              })();
            }}
          />
        </SettingsGroup>
      </>
    );
  } else if (complete) {
    uploaded = (
      <SettingsGroup
        title={t('errorReporting.uploaded')}
        footer={t('errorReporting.completeDescription')}>
        <SettingsRow title={t('errorReporting.completeTitle')} />
      </SettingsGroup>
    );
  } else {
    uploaded = (
      <SettingsGroup
        ref={anchor}
        title={t('errorReporting.uploaded')}
        footer={
          missing
            ? t('errorReporting.missing')
            : `${t('errorReporting.deleteExplanation')}\n\n${t('errorReporting.missing')}`
        }>
        <ReportingAction
          label={t('errorReporting.delete')}
          disabled={!available || missing}
          destructive
          onPress={() => {
            void confirmation();
          }}
        />
      </SettingsGroup>
    );
  }
  return (
    <>
      <SettingsGroup
        title={t('errorReporting.title')}
        footer={consentDescription}>
        <SettingsRow
          title={t('errorReporting.share')}
          disabled={!available}>
          <Switch
            accessibilityLabel={t('errorReporting.share')}
            accessibilityState={{
              disabled: !available,
              busy: snapshot.kind === 'saving',
            }}
            disabled={!available}
            value={enabled}
            trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
            onValueChange={(value) => {
              void store.setEnabled(value);
            }}
          />
        </SettingsRow>
      </SettingsGroup>
      {snapshot.kind === 'loading' || snapshot.kind === 'saving' ? (
        <ActivityIndicator
          accessibilityLabel={
            snapshot.kind === 'loading'
              ? t('errorReporting.loading')
              : t('errorReporting.saving')
          }
        />
      ) : null}
      {snapshot.kind === 'unavailable' ? (
        <SettingsGroup footer={t('errorReporting.unavailable')} />
      ) : null}
      <SettingsGroup
        title={t('errorReporting.whatIsShared')}
        footer={t('errorReporting.sharedDetails')}
      />
      {uploaded}
    </>
  );
}
