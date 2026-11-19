import { spacing } from '@private-email/mail-core/theme';
import { use, useEffect, useLayoutEffect, useState } from 'react';
import { AccessibilityInfo, Platform, StyleSheet, View } from 'react-native';

import type { SaveOutcome } from './message-body.tsx';

import { Action } from './action.tsx';
import { Notice, Toast } from './design.tsx';
import { WindowBarContext } from './inbox-bar.tsx';
import { useLocalization } from './localization.ts';
import { openLink, useReaderScrollTo } from './message-body.tsx';
import { usePalette } from './theme.ts';

const compact = Platform.OS === 'ios' && !Platform.isPad;

const styles = StyleSheet.create({
  toast: {
    position: 'absolute',
    left: spacing.l,
    right: spacing.l,
    alignItems: 'center',
  },
});

// How long a saved copy's toast stays.
const savedToastDuration = 6000;

// The reader's latest Save to Files outcome and the way to report one. A saved copy's toast leaves
// on its own; a failure stays until the next outcome or another message. Both are announced.
export function useSaveOutcome(message: string) {
  const { t } = useLocalization();
  const [shown, setShown] =
    useState<
      Readonly<{ outcome: SaveOutcome; message: string; open: boolean }>
    >();
  const current = shown?.message === message ? shown : undefined;
  useEffect(() => {
    if (current?.outcome.kind !== 'saved' || !current.open) {
      return;
    }
    const timer = setTimeout(() => {
      setShown((last) => last && { ...last, open: false });
    }, savedToastDuration);
    return () => {
      clearTimeout(timer);
    };
  }, [current]);
  const report = (outcome: SaveOutcome) => {
    setShown({ outcome, message, open: true });
    AccessibilityInfo.announceForAccessibility(
      outcome.kind === 'saved'
        ? t('attachment.savedNamed', outcome.copy)
        : t('attachment.saveFailed', { name: outcome.name }),
    );
  };
  return { shown: current, report };
}

type Shown = ReturnType<typeof useSaveOutcome>['shown'];

// The iPhone reader's failure, at the top of its content.
export function SaveFailedNotice({ shown }: { readonly shown: Shown }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const scrollTo = useReaderScrollTo();
  // The notice sits at the top of the reader, above the attachment that failed.
  useEffect(() => {
    if (compact && shown?.outcome.kind === 'failed') {
      scrollTo?.(0);
    }
  }, [shown, scrollTo]);
  if (!compact || shown?.outcome.kind !== 'failed') {
    return null;
  }
  const { name, retry } = shown.outcome;
  return (
    <Notice
      icon="exclamationmark.triangle"
      iconColor={colors.statusWarning}
      message={t('attachment.saveFailed', { name })}
      detail={t('attachment.saveFailedDetail')}
      messageRole="alert">
      <Action
        label={t('attachment.saveToFiles')}
        accessibilityLabel={t('attachment.saveToFilesLabel', { name })}
        onPress={retry}
      />
    </Notice>
  );
}

// The toast for a saved copy, with Show to find it in Files, and on iPad for a failure too: above
// the iPhone reader's toolbar at `bottom`, or with the window bar's notices on iPad.
export function SaveOutcomeToast({
  shown,
  bottom,
}: {
  readonly shown: Shown;
  readonly bottom: number;
}) {
  const { t } = useLocalization();
  const windowBar = use(WindowBarContext);
  // The words outlast the toast so it can fade out.
  const [said, setSaid] = useState(shown);
  if (shown !== undefined && shown !== said) {
    setSaid(shown);
  }
  let toast = null;
  if (said?.outcome.kind === 'saved') {
    const { copy } = said.outcome;
    toast = (
      <Toast
        open={shown?.open === true}
        symbol="square.and.arrow.down"
        message={
          compact
            ? t('attachment.saved', copy)
            : t('attachment.savedNamed', copy)
        }
        detail={compact ? copy.name : undefined}
        action={t('attachment.show')}
        accessibilityLabel={t('attachment.showLabel', copy)}
        onAction={() => {
          void openLink(copy.show);
        }}
      />
    );
  } else if (said?.outcome.kind === 'failed' && !compact) {
    const { name, retry } = said.outcome;
    toast = (
      <Toast
        open={shown?.open === true}
        symbol="exclamationmark.triangle.fill"
        message={t('attachment.saveFailed', { name })}
        detail={t('attachment.saveFailedDetail')}
        action={t('attachment.saveToFiles')}
        accessibilityLabel={t('attachment.saveToFilesLabel', { name })}
        onAction={retry}
      />
    );
  }
  useLayoutEffect(() => {
    windowBar?.showReaderNotice(toast);
  });
  useLayoutEffect(
    () => () => {
      windowBar?.showReaderNotice(null);
    },
    [windowBar],
  );
  return windowBar === undefined && toast !== null ? (
    <View
      pointerEvents="box-none"
      style={[styles.toast, { bottom }]}>
      {toast}
    </View>
  ) : null;
}
